#!/usr/bin/env bash
# /gh-fix-issue のプロジェクト別設定を読み込む。各スクリプトから source される。
#
# スクリプト本体は ~/.claude/scripts/ に置かれ、複数のリポジトリから共有される。
# そのためリポジトリ固有の値（ビルドコマンド・base ブランチ・Projects 名など）は
# ここでは持たず、各リポジトリの設定ファイルから読む。
#
#   <リポジトリルート>/.claude/gh-fix-issue.config.sh
#
# 設定ファイルが無いリポジトリでは、下記の既定値で動く。
# 既定値は「Gradle も GitHub Projects も使わない素の Git リポジトリ」を想定している。
#
# リポジトリルートはスクリプトの位置からは求められない（スクリプトはリポジトリの外にある）。
# 必ず git に問い合わせる。

# shellcheck disable=SC2034

resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

load_gh_fix_issue_config() {
  GH_FIX_ISSUE_REPO_ROOT="$(resolve_repo_root)"
  if [ -z "$GH_FIX_ISSUE_REPO_ROOT" ]; then
    echo "Git リポジトリの中で実行してください。" >&2
    return 1
  fi

  # ---- 既定値 ----
  GH_FIX_ISSUE_BASE_BRANCH="main"
  GH_FIX_ISSUE_BRANCH_TEMPLATE="feature/fix_{issue}"
  # ビルド/テストを実行するディレクトリ。リポジトリルートからの相対パス。
  GH_FIX_ISSUE_BUILD_DIR="."
  # ゲート。1 行 1 ゲートで "表示名<TAB>コマンド" 形式。空ならゲート無し。
  GH_FIX_ISSUE_GATES=""
  # lint ゲート。空なら lint ゲート自体を行わない。
  GH_FIX_ISSUE_LINT_CMD=""
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

  return 0
}
