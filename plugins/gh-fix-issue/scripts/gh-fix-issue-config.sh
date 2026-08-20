#!/usr/bin/env bash
# /gh-fix-issue のプロジェクト別設定を読み込む。各スクリプトから source される。
#
# スクリプト本体はプラグイン側に置かれ、複数のリポジトリから共有される。
# そのためリポジトリ固有の値（ビルドコマンド・base ブランチ・Projects 名など）は
# ここでは持たず、各リポジトリの設定ファイルから読む。
#
#   <リポジトリルート>/.claude/gh-fix-issue.config.sh
#
# 雛形は presets/gh-fix-issue.config.sh.example にある。丸ごとコピーして使う:
#
#   cp "$GH_FIX_ISSUE_PRESET_DIR/gh-fix-issue.config.sh.example" \
#      .claude/gh-fix-issue.config.sh
#
# 設定ファイルが無いリポジトリでも動くが、その場合ビルドもテストも lint も実行しない。
# 「検証していない」ことが黙って通り過ぎないよう、警告を出す（下記 warn_if_unconfigured）。
#
# base ブランチは決め打ちしない。既定ブランチが main のリポジトリと develop の
# リポジトリが混在するため、"main" を既定値にすると develop 運用のリポジトリで
# 「存在しないブランチを base として扱う」状態になる。実在しないなら fetch で
# 落ちるので気づけるが、main が存在する develop 運用のリポジトリでは
# **気づかないまま間違った base で PR が出る**。git / gh から解決し、
# どちらからも取れなければ空のままにして呼び出し側に失敗させる。
#
# リポジトリルートはスクリプトの位置からは求められない（スクリプトはリポジトリの外にある）。
# 必ず git に問い合わせる。

# shellcheck disable=SC2034

# 自分自身の位置を **source した時点で** 記録する。関数の中では取れない:
#   - zsh は BASH_SOURCE を持たず、関数内の $0 は関数名になる
#   - bash の $0 は "bash" になる
# このローカーは bash スクリプトからも、/gh-fix-issue のコマンド手順が実行する
# シェル（zsh のこともある）からも source される。どちらでも presets/ を指せるように、
# ここで一度だけ解決しておく。source 時のカレントディレクトリで絶対パス化する
# （後で cd されても壊れないように）。
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  __GH_FIX_ISSUE_LOADER_SRC="${BASH_SOURCE[0]}"
else
  __GH_FIX_ISSUE_LOADER_SRC="$0"
fi
__GH_FIX_ISSUE_LOADER_DIR="$(cd "$(dirname "$__GH_FIX_ISSUE_LOADER_SRC")" 2>/dev/null && pwd)"

resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

# リモートの既定ブランチ名を返す。取れなければ空文字を返す（決め打ちしない）。
#
# 1. refs/remotes/origin/HEAD — clone 時に設定されるローカルの参照。ネットワーク不要
# 2. gh repo view           — 1 が無いとき（CI の浅い checkout など）の権威ある情報源
resolve_default_branch() {
  local ref name
  ref="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -n "$ref" ]; then
    # "origin/develop" → "develop"
    printf '%s\n' "${ref#origin/}"
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    name="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)"
    if [ -n "$name" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi

  return 1
}

# 設定ファイルが無いことを警告する。ゲートが 1 つも無い状態で実装から PR まで
# 通ってしまうと「一度も検証されていない PR」が緑に見えるため、必ず知らせる。
# 呼び出し側（コマンド・スクリプト）が任意のタイミングで呼べるよう関数に分けている。
warn_if_unconfigured() {
  [ -n "${GH_FIX_ISSUE_CONFIG_LOADED:-}" ] && return 0
  echo "警告: ${GH_FIX_ISSUE_REPO_ROOT:-.}/.claude/gh-fix-issue.config.sh がありません。" >&2
  echo "      ビルド・テスト・lint のゲートは 1 つも実行されません（未検証のまま PR まで進みます）。" >&2
  echo "      雛形: ${GH_FIX_ISSUE_PRESET_DIR:-<plugin>/presets}/gh-fix-issue.config.sh.example" >&2
  return 0
}

load_gh_fix_issue_config() {
  GH_FIX_ISSUE_REPO_ROOT="$(resolve_repo_root)"
  if [ -z "$GH_FIX_ISSUE_REPO_ROOT" ]; then
    echo "Git リポジトリの中で実行してください。" >&2
    return 1
  fi

  # プリセットと雛形の置き場所。設定ファイル側から
  #   . "$GH_FIX_ISSUE_PRESET_DIR/android-gradle.sh"
  # のように参照できるよう、設定を source する前に決めておく。
  # 位置はファイル冒頭（source 時）に記録済み。
  if [ -n "${__GH_FIX_ISSUE_LOADER_DIR:-}" ]; then
    GH_FIX_ISSUE_PRESET_DIR="$(cd "$__GH_FIX_ISSUE_LOADER_DIR/.." && pwd)/presets"
  else
    GH_FIX_ISSUE_PRESET_DIR=""
  fi

  # ---- 既定値 ----
  # base ブランチは決め打ちしない。設定ファイルが指定しなければ後段で解決する。
  GH_FIX_ISSUE_BASE_BRANCH=""
  GH_FIX_ISSUE_BRANCH_TEMPLATE="feature/fix_{issue}"
  # ビルド/テストを実行するディレクトリ。リポジトリルートからの相対パス。
  GH_FIX_ISSUE_BUILD_DIR="."
  # ゲート。1 行 1 ゲートで "表示名<TAB>コマンド" 形式。空ならゲート無し。
  GH_FIX_ISSUE_GATES=""
  # lint ゲート。空なら lint ゲート自体を行わない。
  GH_FIX_ISSUE_LINT_CMD=""
  GH_FIX_ISSUE_LINT_NAME=""
  GH_FIX_ISSUE_LINT_REPORT_DIR=""
  # 追加行だけを対象にする lint 判定を使うか（checkstyle XML 形式のみ対応）
  GH_FIX_ISSUE_LINT_DIFF_ENABLED=""
  # GitHub Projects。空なら Projects の更新を行わない。
  GH_FIX_ISSUE_ISSUE_PROJECT=""
  GH_FIX_ISSUE_PR_PROJECT=""
  GH_FIX_ISSUE_STATUS_START=""
  GH_FIX_ISSUE_STATUS_REVIEWED=""
  GH_FIX_ISSUE_STATUS_PR=""
  # Codex に渡すレビュー基準。リポジトリルートからの相対パス。
  GH_FIX_ISSUE_FOCUS_FILE=""
  # Codex に読ませる規約ファイル（空白区切り）
  GH_FIX_ISSUE_REVIEW_DOCS=""

  local config="$GH_FIX_ISSUE_REPO_ROOT/.claude/gh-fix-issue.config.sh"
  if [ -f "$config" ]; then
    # shellcheck source=/dev/null
    . "$config"
    GH_FIX_ISSUE_CONFIG_LOADED="$config"
  else
    GH_FIX_ISSUE_CONFIG_LOADED=""
  fi

  # 設定が base を指定しなかった場合だけ解決する。指定済みのリポジトリに
  # gh のネットワーク往復を払わせないため、この順序（source した後）で行う。
  if [ -z "$GH_FIX_ISSUE_BASE_BRANCH" ]; then
    GH_FIX_ISSUE_BASE_BRANCH="$(resolve_default_branch)" || GH_FIX_ISSUE_BASE_BRANCH=""
  fi

  return 0
}
