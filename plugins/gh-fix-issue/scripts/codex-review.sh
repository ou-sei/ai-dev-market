#!/usr/bin/env bash
# Codex レビューを1周実行し、対応必須の指摘の有無を終了コードで返す。
#
#   codex-review.sh --check
#   codex-review.sh --round <N> --base <ref>
#   codex-review.sh --discuss <message>
#
# 終了コード:
#   0  対応必須(critical/high)なし / --discuss が応答を得た
#   10 対応必須あり
#   20 --round が上限を超えた
#   30 Codex が使えない
#   1  実行失敗
#
# --discuss は「指摘が誤っていると考えたときに Codex へ反論して見解を求める」ための口。
# **--round を取らず findings-<N>.json も書き換えない**ので、何回使ってもレビューの
# ラウンド数は増えない。ディスカッションをループ回数に数えないという規則を、運用の
# 約束ではなくインターフェースの形で保証している。
# --discuss は 10 を返さない。指摘を採るか採らないかの判断は呼び出し側（Claude）の仕事で、
# ここでは Codex の見解を取得できたかどうかだけを返す。
#
# 環境変数（詳細は .claude/scripts/README.md）:
#   CODEX_COMPANION            codex-companion.mjs のパスを固定する
#   GH_FIX_ISSUE_FINDINGS_DIR   findings の保存先を変える
#   CODEX_REVIEW_FIXTURE       テスト専用。Codex を呼ばず固定 JSON を判定結果に使う
#   CODEX_REVIEW_DISABLE_GLOB  テスト専用。companion の glob フォールバックを止める
set -uo pipefail

EXIT_CLEAN=0
EXIT_MUST_FIX=10
EXIT_ROUND_EXCEEDED=20
EXIT_UNAVAILABLE=30
EXIT_ERROR=1
MAX_ROUNDS=4

resolve_companion() {
  if [ -n "${CODEX_COMPANION:-}" ]; then
    if [ -f "$CODEX_COMPANION" ]; then
      printf '%s\n' "$CODEX_COMPANION"
      return 0
    fi
    if [ -n "${CODEX_REVIEW_DISABLE_GLOB:-}" ]; then
      return 1
    fi
  fi

  local candidate
  candidate="$(ls -1 "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null \
    | sort -V | tail -1)"
  [ -n "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

cmd_check() {
  local companion
  if ! companion="$(resolve_companion)"; then
    echo "codex companion が見つかりません。/codex:setup で Codex を設定してください。" >&2
    return "$EXIT_UNAVAILABLE"
  fi
  echo "codex companion: $companion"
  return "$EXIT_CLEAN"
}

# スクリプトはリポジトリ外（~/.claude/scripts/）に置かれるため、位置からリポジトリルートを
# 求めることはできない。設定ローダーが git に問い合わせて解決する。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/gh-fix-issue-config.sh"
if ! load_gh_fix_issue_config; then
  exit 1
fi
REPO_ROOT="$GH_FIX_ISSUE_REPO_ROOT"

# レビュー基準はリポジトリごとに異なる。設定で指定されたファイルを使い、
# 無指定なら汎用的な観点にフォールバックする。
build_focus_text() {
  local focus_file="${GH_FIX_ISSUE_FOCUS_FILE:-}"
  if [ -n "$focus_file" ] && [ -f "$REPO_ROOT/$focus_file" ]; then
    cat "$REPO_ROOT/$focus_file"
    return 0
  fi

  local docs="${GH_FIX_ISSUE_REVIEW_DOCS:-}"
  if [ -n "$docs" ]; then
    echo "このリポジトリの ${docs} を必ず読み、そこに書かれた基準でレビューしてください。"
  fi
  cat <<'FALLBACK'
重点を置く観点:
- クラッシュ・データ破壊・情報漏えいにつながる欠陥
- null / 境界値 / 例外経路の取りこぼし
- 認証情報・個人情報のログ出力
- 並行処理の競合、リソースリーク
指摘してはいけないもの:
- フォーマット、import 順など lint が扱う範囲
FALLBACK
}

FOCUS_TEXT="$(build_focus_text)"

# result --json の出力から verdict と findings を併せ持つオブジェクトを再帰探索して取り出す
extract_review() {
  node -e '
let raw = "";
process.stdin.on("data", (d) => { raw += d; });
process.stdin.on("end", () => {
  let data;
  try { data = JSON.parse(raw); } catch (e) { process.exit(3); }
  const seen = new Set();
  const find = (node) => {
    if (!node || typeof node !== "object") return null;
    if (seen.has(node)) return null;
    seen.add(node);
    if (typeof node.verdict === "string" && Array.isArray(node.findings)) return node;
    const children = Array.isArray(node) ? node : Object.values(node);
    for (const child of children) {
      const hit = find(child);
      if (hit) return hit;
    }
    return null;
  };
  const review = find(data);
  if (!review) process.exit(4);
  process.stdout.write(JSON.stringify(review));
});'
}

# レビュー JSON を人間可読に整形し、対応必須の件数を最終行に出す。
# severity が既知集合 {critical,high,medium,low} に無い場合（欠落・大文字違い・
# "blocker" 等の未知の値）は fail-open で「任意」に倒さず、対応必須(fail-closed)として扱う。
render_review() {
  node -e '
let raw = "";
process.stdin.on("data", (d) => { raw += d; });
process.stdin.on("end", () => {
  const review = JSON.parse(raw);
  const known = new Set(["critical", "high", "medium", "low"]);
  const rank = { critical: 0, high: 1, medium: 2, low: 3 };
  const isMustFix = (f) => !known.has(f.severity) || f.severity === "critical" || f.severity === "high";
  const findings = [...(review.findings || [])].sort(
    (a, b) => (rank[a.severity] ?? 9) - (rank[b.severity] ?? 9)
  );
  const mustFix = findings.filter(isMustFix);
  const lines = [];
  lines.push(`verdict: ${review.verdict}`);
  lines.push(`summary: ${review.summary}`);
  lines.push("");
  if (findings.length === 0) {
    lines.push("指摘なし。");
  } else {
    for (const f of findings) {
      const severityLabel = known.has(f.severity) ? f.severity : "不明";
      const must = isMustFix(f) ? "対応必須" : "任意";
      const range = f.line_end && f.line_end !== f.line_start
        ? `${f.line_start}-${f.line_end}`
        : `${f.line_start}`;
      lines.push(`[${severityLabel}] (${must}) ${f.title}`);
      lines.push(`  ${f.file}:${range}`);
      lines.push(`  ${f.body}`);
      if (f.recommendation) lines.push(`  → ${f.recommendation}`);
      lines.push("");
    }
  }
  lines.push(`must_fix=${mustFix.length}`);
  process.stdout.write(lines.join("\n") + "\n");
});'
}

cmd_round() {
  local round="$1" base="$2"

  if [ "$round" -gt "$MAX_ROUNDS" ]; then
    echo "ラウンド上限 ($MAX_ROUNDS) を超えました。対応必須の指摘が残っています。" >&2
    return "$EXIT_ROUND_EXCEEDED"
  fi

  # GH_FIX_ISSUE_FINDINGS_DIR で上書き可能（テスト用）。未設定時は本番と同じパス。
  local findings_dir="${GH_FIX_ISSUE_FINDINGS_DIR:-$REPO_ROOT/.git/gh-fix-issue}"

  # round 1 はこのフローの開始点。前回の Issue の findings-N.json が残っていると
  # 今回の「未対応の指摘」に他 Issue の内容が混入するため、開始時にクリアする。
  if [ "$round" -eq 1 ]; then
    rm -rf "$findings_dir"
  fi

  if ! mkdir -p "$findings_dir"; then
    echo "findings 保存用ディレクトリの作成に失敗しました: $findings_dir" >&2
    return "$EXIT_ERROR"
  fi

  local result_json
  if [ -n "${CODEX_REVIEW_FIXTURE:-}" ]; then
    echo "警告: CODEX_REVIEW_FIXTURE が設定されているため、Codex を呼び出さずに固定の判定結果を返します。実際のレビューは実行されていません。" >&2
    result_json="$(cat "$CODEX_REVIEW_FIXTURE")"
  else
    local companion
    if ! companion="$(resolve_companion)"; then
      echo "codex companion が見つかりません。/codex:setup で Codex を設定してください。" >&2
      return "$EXIT_UNAVAILABLE"
    fi

    echo "Codex レビュー ラウンド $round/$MAX_ROUNDS (base=$base) を実行中..." >&2
    if ! node "$companion" adversarial-review --wait --base "$base" --scope branch "$FOCUS_TEXT" >&2; then
      echo "Codex レビューの実行に失敗しました。" >&2
      return "$EXIT_ERROR"
    fi

    if ! result_json="$(node "$companion" result --json 2>/dev/null)"; then
      echo "Codex の結果取得に失敗しました。" >&2
      return "$EXIT_ERROR"
    fi
  fi

  local review
  if ! review="$(printf '%s' "$result_json" | extract_review)"; then
    echo "Codex が構造化 JSON を返しませんでした。" >&2
    return "$EXIT_ERROR"
  fi

  printf '%s' "$review" > "$findings_dir/findings-$round.json"

  local rendered
  if ! rendered="$(printf '%s' "$review" | render_review)"; then
    echo "レビュー結果の整形に失敗しました。判定を信用できないため実行エラーとして停止します。" >&2
    return "$EXIT_ERROR"
  fi
  printf '%s\n' "$rendered"

  local must_fix
  must_fix="$(printf '%s\n' "$rendered" | sed -n 's/^must_fix=//p' | tail -1)"

  if ! [[ "$must_fix" =~ ^[0-9]+$ ]]; then
    echo "must_fix の値が不正です（'$must_fix'）。判定を信用できないため実行エラーとして停止します。" >&2
    return "$EXIT_ERROR"
  fi

  if [ "$must_fix" -gt 0 ]; then
    return "$EXIT_MUST_FIX"
  fi
  return "$EXIT_CLEAN"
}

# Codex に反論・質問を投げて見解を得る。ラウンドは消費しない。
#
# レビュー本体（adversarial-review）のスレッドは task 履歴に残らないため
# `task --resume-last` では継続できない。代わりに毎回新しいスレッドを立て、
# 反論の材料（指摘の全文と該当コード）を呼び出し側が本文に含める前提にしている。
# 前の結論に引きずられない分、二次意見としてはむしろ素直に働く。
cmd_discuss() {
  local message="$1"

  if [ -z "$message" ]; then
    echo "usage: codex-review.sh --discuss <message>" >&2
    return "$EXIT_ERROR"
  fi

  local companion
  if ! companion="$(resolve_companion)"; then
    echo "codex companion が見つかりません。/codex:setup で Codex を設定してください。" >&2
    return "$EXIT_UNAVAILABLE"
  fi

  echo "Codex にディスカッションを依頼中（レビューのラウンドは消費しません）..." >&2

  local out
  if ! out="$(node "$companion" task --fresh "$message" 2>&1)"; then
    printf '%s\n' "$out" >&2
    echo "Codex への問い合わせに失敗しました。" >&2
    return "$EXIT_ERROR"
  fi

  printf '%s\n' "$out"

  # やりとりを残す。PR 本文で「なぜ指摘に従わなかったか」を示す根拠になる。
  # findings ディレクトリは --round 1 で作り直されるが、ディスカッションは
  # 必ず 1 周目のレビューより後に起きるので消えない。
  local findings_dir="${GH_FIX_ISSUE_FINDINGS_DIR:-$REPO_ROOT/.git/gh-fix-issue}"
  if mkdir -p "$findings_dir" 2>/dev/null; then
    {
      echo "## $(date '+%Y-%m-%d %H:%M:%S')"
      echo
      echo "### Claude からの問い"
      echo
      printf '%s\n' "$message"
      echo
      echo "### Codex の回答"
      echo
      printf '%s\n' "$out"
      echo
      echo "---"
      echo
    } >> "$findings_dir/discussion.md"
  fi

  return "$EXIT_CLEAN"
}

main() {
  case "${1:-}" in
    --check)
      cmd_check
      return $?
      ;;
    --discuss)
      cmd_discuss "${2:-}"
      return $?
      ;;
    --round)
      local round="${2:-}" base=""
      if [ "${3:-}" = "--base" ]; then
        base="${4:-}"
      fi
      if [ -z "$round" ] || [ -z "$base" ]; then
        echo "usage: codex-review.sh --round <N> --base <ref>" >&2
        return "$EXIT_ERROR"
      fi
      if ! [[ "$round" =~ ^[0-9]+$ ]]; then
        echo "usage: codex-review.sh --round <N> --base <ref> (N は数値)" >&2
        return "$EXIT_ERROR"
      fi
      cmd_round "$round" "$base"
      return $?
      ;;
    *)
      echo "usage: codex-review.sh --check | --round <N> --base <ref> | --discuss <message>" >&2
      return "$EXIT_ERROR"
      ;;
  esac
}

main "$@"
exit $?
