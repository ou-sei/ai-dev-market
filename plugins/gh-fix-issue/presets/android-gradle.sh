#!/usr/bin/env bash
# Android / Gradle リポジトリ向けのプリセット。
#
# リポジトリ側の .claude/gh-fix-issue.config.sh から読み込み、
# 差分だけを後ろで上書きする:
#
#   . "$GH_FIX_ISSUE_PRESET_DIR/android-gradle.sh"
#
#   GH_FIX_ISSUE_BASE_BRANCH="develop"
#   GH_FIX_ISSUE_BUILD_DIR="app-root"          # Git ルート != Gradle ルート のとき
#
#   # フレーバーがあるなら、そのプロジェクトのタスク名に置き換える
#   # （<Flavor> は productFlavor 名。例: assembleStagingDebug）
#   GH_FIX_ISSUE_GATES="$(printf 'assemble<Flavor>Debug\t%s assemble<Flavor>Debug' \
#     "$GH_FIX_ISSUE_GRADLE")"
#
# **このファイルはプラグイン側にあるので、特定リポジトリの値を書かないこと。**
# フレーバー名やタスク名はプロジェクトごとに違うため、ここでは「Gradle をどう呼ぶか」と
# 「ktlint をどう判定するか」だけを決める。
#
# shellcheck disable=SC2034

# gradlew の呼び出し方。PREFLIGHT_GRADLE はテストが gradlew を差し替えるための口で、
# ゲートのコマンド文字列の中で展開される（設定ファイル側でもこの形を使う）。
GH_FIX_ISSUE_GRADLE='"${PREFLIGHT_GRADLE:-./gradlew}"'

# Gradle ルートはリポジトリルートと一致することが多いが、一致しない構成もある。
# 一致しない場合は読み込み側で上書きする。
GH_FIX_ISSUE_BUILD_DIR="."

# ゲートの既定。タスク名はプロジェクト依存なので、最も素朴な組み合わせにしておく。
# フレーバーがあるリポジトリは読み込み側で上書きする。
GH_FIX_ISSUE_GATES="$(printf 'assembleDebug\t%s assembleDebug\ntest\t%s test' \
  "$GH_FIX_ISSUE_GRADLE" "$GH_FIX_ISSUE_GRADLE")"

# ---- ktlint ------------------------------------------------------------------
#
# ktlint は ignoreFailures=true で運用されているリポジトリが多く、既存違反が
# 大量にあるとレポート全体では常に不合格になる。そのため「この PR の追加行の
# 違反だけ」を判定する（CHECKSTYLE レポーターの XML が必要）。
GH_FIX_ISSUE_LINT_NAME="ktlintCheck"
GH_FIX_ISSUE_LINT_CMD="$GH_FIX_ISSUE_GRADLE ktlintCheck"
# GH_FIX_ISSUE_BUILD_DIR からの相対パス。単一モジュール構成での標準的な出力先。
GH_FIX_ISSUE_LINT_REPORT_DIR="app/build/reports/ktlint"
GH_FIX_ISSUE_LINT_DIFF_ENABLED="1"
