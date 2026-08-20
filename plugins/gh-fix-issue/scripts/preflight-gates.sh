#!/usr/bin/env bash
# PUSH 前のゲート。build / unit test / ktlint を順に実行する。
# <repo-root>/.claude/gh-fix-issue.gates.sh があれば、それに委譲する。
#
#   preflight-gates.sh [--base <ref>]
#
# 終了コード: 0 = 全通過 / 10 = いずれか不合格 / 1 = 実行失敗
#   exit 1 は「ゲートの実行基盤自体が失敗した」= 結果全体が信用できない状態であり、
#   exit 10（不合格。直して再実行する）とは区別する。
#
# 環境変数（詳細は .claude/scripts/README_ja.md）:
#   PREFLIGHT_GRADLE             gradlew の代わりに使うコマンド
#   PREFLIGHT_SKIP_KTLINT        テスト専用。ktlint ゲートを丸ごと飛ばす
#   PREFLIGHT_KTLINT_REPORT_DIR  ktlint レポートの探索先を変える
#   PREFLIGHT_KTLINT_DIFF_FILE   --base の代わりに diff ファイルを ktlint-diff.mjs へ渡す
set -uo pipefail

# スクリプトはリポジトリ外（~/.claude/scripts/）に置かれるため、位置からリポジトリルートを
# 求めることはできない。設定ローダーが git に問い合わせて解決する。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/gh-fix-issue-config.sh"

EXIT_OK=0
EXIT_FAILED=10
EXIT_ERROR=1

if ! load_gh_fix_issue_config; then
  exit "$EXIT_ERROR"
fi
REPO_ROOT="$GH_FIX_ISSUE_REPO_ROOT"
BUILD_DIR="$REPO_ROOT/${GH_FIX_ISSUE_BUILD_DIR:-.}"

usage() {
  echo "使い方: preflight-gates.sh [--base <ref>]" >&2
}

BASE_REF="${GH_FIX_ISSUE_BASE_BRANCH:-}"
if [ "$#" -eq 0 ]; then
  :
elif [ "$#" -eq 2 ] && [ "$1" = "--base" ] && [ -n "$2" ]; then
  BASE_REF="$2"
else
  usage
  exit "$EXIT_ERROR"
fi

# base を決め打ちしない（"main" にフォールバックしない）。既定ブランチが develop の
# リポジトリで main を base として扱うと、差分の基準がずれたまま lint 判定が通る。
# 解決できないなら、間違った基準で判定するより止める。
if [ -z "$BASE_REF" ]; then
  echo "base ブランチを解決できませんでした。" >&2
  echo "--base <ref> で明示するか、設定 GH_FIX_ISSUE_BASE_BRANCH を指定してください。" >&2
  exit "$EXIT_ERROR"
fi

# リポジトリ側の上書きゲートがあれば、それに委譲する。契約は同じ 0 / 10 / 1 なので
# 終了コードをそのまま返す。上書きファイルはプラグインごとに独立させる
# （.claude/<プラグイン名>.gates.sh）。共有ファイルにすると、他のプラグイン用に置いた
# 定義がこのプラグインの動作（config のゲートや ktlint 差分判定）を止めてしまい、
# 単独利用の原則が崩れる（docs/plugin-distribution.md §5）。
GATES_OVERRIDE="$REPO_ROOT/.claude/gh-fix-issue.gates.sh"
if [ -f "$GATES_OVERRIDE" ]; then
  echo "== ${GATES_OVERRIDE#"$REPO_ROOT/"}（リポジトリ側の上書きゲートに委譲）"
  bash "$GATES_OVERRIDE"
  exit $?
fi

if [ ! -d "$BUILD_DIR" ]; then
  echo "ビルドディレクトリが見つかりません: ${BUILD_DIR}（設定 GH_FIX_ISSUE_BUILD_DIR を確認してください）" >&2
  exit "$EXIT_ERROR"
fi

failed=""
skipped=""
# 実際に実行したゲートの数。0 のまま終わるのを「合格」と report しないために数える。
ran=0

# ゲートを1つ実行する。コマンドは BUILD_DIR で評価する。
run_gate() {
  local name="$1" cmd="$2"
  ran=$((ran + 1))
  echo "== $name"
  if ( cd "$BUILD_DIR" && eval "$cmd" ); then
    echo "   OK"
    return 0
  fi
  echo "   FAILED"
  failed="$failed $name"
  return 1
}

# ゲート定義は "表示名<TAB>コマンド" を1行1件で持つ。設定が空ならビルド/テストは行わない。
# PREFLIGHT_GRADLE はテスト用の差し替え口として残す（設定側のコマンド内で参照される）。
if [ -n "${GH_FIX_ISSUE_GATES:-}" ]; then
  while IFS=$'\t' read -r gate_name gate_cmd; do
    [ -z "$gate_name" ] && continue
    run_gate "$gate_name" "$gate_cmd"
  done <<< "$GH_FIX_ISSUE_GATES"
fi

# lint ゲート。GH_FIX_ISSUE_LINT_CMD が空なら、このリポジトリでは lint ゲートを行わない。
if [ -n "${GH_FIX_ISSUE_LINT_CMD:-}" ] && [ -z "${PREFLIGHT_SKIP_KTLINT:-}" ]; then
  ran=$((ran + 1))
  echo "== ${GH_FIX_ISSUE_LINT_NAME:-lint}"
  # lint タスク自体の実行失敗（設定エラー・パースできない構文・デーモン異常等）は
  # rc != 0 で返る。rc を無視すると、レポートが再生成されないまま前回実行時の
  # 古い XML を読み、一度も検証されていないのに「違反なし」で合格してしまう。
  # （ktlint の ignoreFailures=true が無効化するのは「違反による失敗」だけ）
  ( cd "$BUILD_DIR" && eval "$GH_FIX_ISSUE_LINT_CMD" ) >/dev/null 2>&1
  ktlint_task_rc=$?

  if [ "$ktlint_task_rc" -ne 0 ]; then
    echo "   ERROR" >&2
    echo "lint タスク自体が失敗しました (exit $ktlint_task_rc)。レポートが再生成されていない可能性があり、判定結果を信用できないため中断します。" >&2
    exit "$EXIT_ERROR"
  fi

  # レポート出力先・diff の入力先はテストのために上書き可能にする（後方互換：
  # 未設定時は設定ファイルの値を使う）。
  KTLINT_REPORT_DIR="${PREFLIGHT_KTLINT_REPORT_DIR:-$BUILD_DIR/${GH_FIX_ISSUE_LINT_REPORT_DIR:-}}"

  ktlint_diff_args=(--report-dir "$KTLINT_REPORT_DIR" --repo-root "$REPO_ROOT")
  if [ -n "${PREFLIGHT_KTLINT_DIFF_FILE:-}" ]; then
    ktlint_diff_args+=(--diff-file "$PREFLIGHT_KTLINT_DIFF_FILE")
  else
    ktlint_diff_args+=(--base "$BASE_REF")
  fi

  node "$SCRIPT_DIR/ktlint-diff.mjs" "${ktlint_diff_args[@]}"
  rc=$?

  case "$rc" in
    0)
      echo "   OK"
      ;;
    10)
      echo "   FAILED"
      failed="$failed ktlintCheck"
      ;;
    *)
      # rc=1（レポート未検出・--repo-root 不整合など）や想定外の終了コードは
      # 判定そのものが信用できない実行失敗。他ゲートの結果を待たず即座に中断する。
      echo "   ERROR" >&2
      echo "ktlint-diff.mjs の実行に失敗しました (exit $rc)。判定結果を信用できないため中断します。" >&2
      exit "$EXIT_ERROR"
      ;;
  esac
elif [ -n "${GH_FIX_ISSUE_LINT_CMD:-}" ]; then
  # lint は設定されているが、テスト用の env で意図的に飛ばされた場合。
  # 「検証していない」ことを必ず知らせる。
  echo "== ${GH_FIX_ISSUE_LINT_NAME:-lint}" >&2
  echo "警告: PREFLIGHT_SKIP_KTLINT が設定されているため lint ゲートを実行せずスキップしました。この結果は lint を検証していません。" >&2
  skipped="$skipped ${GH_FIX_ISSUE_LINT_NAME:-lint}"
fi
# GH_FIX_ISSUE_LINT_CMD が未設定のリポジトリでは lint ゲート自体が存在しない。
# 設定上の選択なので警告は出さない。

if [ -n "$failed" ]; then
  echo
  echo "不合格のゲート:$failed" >&2
  exit "$EXIT_FAILED"
fi

# ゲートを1つも実行していないのに「通過しました」と言わない。
# 設定ファイルを読んだのにゲートが 0 個なら、設定とローダーの取り決めが噛み合って
# いない（変数名の変更などで設定が効いていない）。検証していないものを合格にしないため、
# 実行エラーとして落とす。
if [ "$ran" -eq 0 ] && [ -z "$skipped" ]; then
  echo >&2
  if [ -n "${GH_FIX_ISSUE_CONFIG_LOADED:-}" ]; then
    echo "設定ファイルを読み込みましたが、実行できるゲートが 1 つもありませんでした: ${GH_FIX_ISSUE_CONFIG_LOADED}" >&2
    echo "GH_FIX_ISSUE_GATES / GH_FIX_ISSUE_LINT_CMD が設定ローダーの読む名前と一致しているか確認してください。" >&2
    echo "何も検証していないため、合格にはしません。" >&2
    exit "$EXIT_ERROR"
  fi
  echo "警告: このリポジトリにはゲートが設定されていないため、ビルドもテストも lint も実行していません。" >&2
  echo "設定するには <リポジトリルート>/.claude/gh-fix-issue.config.sh を作成してください。" >&2
  echo "雛形をコピーして始められます:" >&2
  echo "  cp \"${GH_FIX_ISSUE_PRESET_DIR:-<plugin>/presets}/gh-fix-issue.config.sh.example\" .claude/gh-fix-issue.config.sh" >&2
  exit "$EXIT_OK"
fi

echo
if [ -n "$skipped" ]; then
  echo "一部のゲートをスキップして通過しました（スキップ:${skipped}）。実行したゲート: ${ran} 件"
else
  echo "すべてのゲートを通過しました（${ran} 件）。"
fi
exit "$EXIT_OK"
