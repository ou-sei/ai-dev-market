# ゲート定義は各リポジトリの .claude/gh-fix-issue.config.sh から読まれる。
# 実リポジトリの設定に依存すると、設定を持たないリポジトリ（例: ai-dev-market の CI）では
# 「ゲートが 0 個 → 何も実行せず合格」で全テストが素通りし、壊れていても緑になる。
# そこで専用の一時 git リポジトリを作り、そこに固定のゲート定義を置いて検証する。
PREFLIGHT_FIXTURE_REPO="$(mktemp -d)"
git -C "$PREFLIGHT_FIXTURE_REPO" init -q .
mkdir -p "$PREFLIGHT_FIXTURE_REPO/.claude"
cat > "$PREFLIGHT_FIXTURE_REPO/.claude/gh-fix-issue.config.sh" <<'FIXTURE_CONFIG'
# shellcheck disable=SC2034
GH_FIX_ISSUE_BASE_BRANCH="develop"
GH_FIX_ISSUE_BUILD_DIR="."
GH_FIX_ISSUE_GATES="$(printf 'assembleDemoDebug\t"${PREFLIGHT_GRADLE:-./gradlew}" assembleDemoDebug\ntestDemoReleaseUnitTest\t"${PREFLIGHT_GRADLE:-./gradlew}" testDemoReleaseUnitTest')"
GH_FIX_ISSUE_LINT_NAME="ktlintCheck"
GH_FIX_ISSUE_LINT_CMD='"${PREFLIGHT_GRADLE:-./gradlew}" ktlintCheck'
GH_FIX_ISSUE_LINT_REPORT_DIR="app/build/reports/ktlint"
FIXTURE_CONFIG

# preflight-gates.sh はカレントディレクトリから git でリポジトリルートを解決するため、
# 以降のテストはこの一時リポジトリの中で実行する。
PREFLIGHT_ORIG_PWD="$PWD"
cd "$PREFLIGHT_FIXTURE_REPO" || exit 1

# 偽の gradlew を用意して、ゲートの合否ロジックだけを検証する
make_fake_gradle() {
  local exit_code="$1"
  local script
  script="$(mktemp)"
  cat > "$script" <<EOF
#!/usr/bin/env bash
echo "fake gradle: \$*"
exit $exit_code
EOF
  chmod +x "$script"
  printf '%s\n' "$script"
}

fake_ok="$(make_fake_gradle 0)"
fake_ng="$(make_fake_gradle 1)"

PREFLIGHT_GRADLE="$fake_ok" \
  PREFLIGHT_SKIP_KTLINT=1 \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base develop >/dev/null 2>&1
assert_eq "0" "$?" "gradle が全て成功すれば 0"

PREFLIGHT_GRADLE="$fake_ng" \
  PREFLIGHT_SKIP_KTLINT=1 \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base develop >/dev/null 2>&1
assert_eq "10" "$?" "ビルドが失敗すれば 10"

out="$(PREFLIGHT_GRADLE="$fake_ng" PREFLIGHT_SKIP_KTLINT=1 \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base develop 2>&1)"
assert_contains "$out" "assembleDemoDebug" "失敗したゲート名を出力する"

# --- Fix Round 1 / Finding 2 回帰: --base の不正な引数は develop に黙ってフォールバックせず exit 1 ---

out_no_value="$(PREFLIGHT_GRADLE="$fake_ok" PREFLIGHT_SKIP_KTLINT=1 \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base 2>&1)"
code_no_value=$?
assert_eq "1" "$code_no_value" "--base の値が無いと exit 1"
assert_contains "$out_no_value" "使い方" "usage を stderr に出す(値欠落)"

out_unknown_flag="$(PREFLIGHT_GRADLE="$fake_ok" PREFLIGHT_SKIP_KTLINT=1 \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --Base develop 2>&1)"
code_unknown_flag=$?
assert_eq "1" "$code_unknown_flag" "--base のタイポ(--Base)は develop にフォールバックせず exit 1"
assert_contains "$out_unknown_flag" "使い方" "usage を stderr に出す(タイポ)"

out_equals_form="$(PREFLIGHT_GRADLE="$fake_ok" PREFLIGHT_SKIP_KTLINT=1 \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base=develop 2>&1)"
code_equals_form=$?
assert_eq "1" "$code_equals_form" "--base=<ref> の = 形式は未対応のため exit 1"
assert_contains "$out_equals_form" "使い方" "usage を stderr に出す(=形式)"

# --- Fix Round 1 / Finding 1 & 3: ktlint 経路（node の rc を 0/10/1 で区別する）---
#
# ktlint-diff.mjs 本体は変更禁止なので、preflight-gates.sh 側の
# PREFLIGHT_KTLINT_REPORT_DIR / PREFLIGHT_KTLINT_DIFF_FILE で経路を制御する
# （どちらも未設定時は本番と同一の挙動になる後方互換の追加）。

# preflight-gates.sh は --repo-root に「git が返すリポジトリルート」を渡す。
# スクリプトは ~/.claude/scripts/ に置かれリポジトリ外にあるため、
# $SCRIPTS_DIR からの相対では求められない。同じ方法で解決する。
REPO_ROOT_FOR_TEST="$(git rev-parse --show-toplevel)"
FAKE_TARGET_REL="app/src/main/kotlin/com/example/app/FakeKtlintGateTarget.kt"

ktlint_report_dir="$(mktemp -d)"
cat > "$ktlint_report_dir/report.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<checkstyle version="8.0">
<file name="$REPO_ROOT_FOR_TEST/$FAKE_TARGET_REL">
<error line="12" column="1" severity="error" message="Unexpected indentation" source="standard:indent" />
</file>
</checkstyle>
EOF

ktlint_diff_hits="$(mktemp)"
cat > "$ktlint_diff_hits" <<EOF
diff --git a/$FAKE_TARGET_REL b/$FAKE_TARGET_REL
--- a/$FAKE_TARGET_REL
+++ b/$FAKE_TARGET_REL
@@ -10,0 +10,4 @@
+    val a = 1
+    val b = 2
+    val c = 3
+    val d = 4
EOF

ktlint_diff_clean="$(mktemp)"
cat > "$ktlint_diff_clean" <<EOF
diff --git a/$FAKE_TARGET_REL b/$FAKE_TARGET_REL
--- a/$FAKE_TARGET_REL
+++ b/$FAKE_TARGET_REL
@@ -30,0 +30,4 @@
+    val e = 1
+    val f = 2
+    val g = 3
+    val h = 4
EOF

ktlint_report_dir_missing="$ktlint_report_dir/does-not-exist"

# ktlint の判定が実行失敗(exit 1)なら、build/test が成功していても全体は 1
# （10 に埋没させない。他ゲートの結果を待たず即座に中断する）
out_ktlint_error="$(PREFLIGHT_GRADLE="$fake_ok" \
  PREFLIGHT_KTLINT_REPORT_DIR="$ktlint_report_dir_missing" \
  PREFLIGHT_KTLINT_DIFF_FILE="$ktlint_diff_hits" \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base develop 2>&1)"
code_ktlint_error=$?
assert_eq "1" "$code_ktlint_error" "ktlint の実行失敗(レポート未検出)は build/test 成功でも 10 にならず 1"

# ktlint が違反あり(exit 10)を返せば全体も 10
out_ktlint_violation="$(PREFLIGHT_GRADLE="$fake_ok" \
  PREFLIGHT_KTLINT_REPORT_DIR="$ktlint_report_dir" \
  PREFLIGHT_KTLINT_DIFF_FILE="$ktlint_diff_hits" \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base develop 2>&1)"
code_ktlint_violation=$?
assert_eq "10" "$code_ktlint_violation" "ktlint に追加行の違反があれば全体も 10"

# ktlint が 0(違反なし)で他ゲートも成功すれば全体も 0
out_ktlint_clean="$(PREFLIGHT_GRADLE="$fake_ok" \
  PREFLIGHT_KTLINT_REPORT_DIR="$ktlint_report_dir" \
  PREFLIGHT_KTLINT_DIFF_FILE="$ktlint_diff_clean" \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base develop >/dev/null 2>&1)"
code_ktlint_clean=$?
assert_eq "0" "$code_ktlint_clean" "ktlint に追加行の違反が無く他ゲートも成功すれば全体も 0"

# --- I-1: ktlintCheck タスク自体が rc != 0 で失敗した場合、ignoreFailures=true でも
# それを揉み消さず、古いレポートを差分判定に渡す前に exit 1 で中断する ---

fake_ktlint_task_fails="$(mktemp)"
cat > "$fake_ktlint_task_fails" <<'EOF'
#!/usr/bin/env bash
echo "fake gradle: $*"
if [ "$1" = "ktlintCheck" ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$fake_ktlint_task_fails"

out_ktlint_task_failure="$(PREFLIGHT_GRADLE="$fake_ktlint_task_fails" \
  PREFLIGHT_KTLINT_REPORT_DIR="$ktlint_report_dir" \
  PREFLIGHT_KTLINT_DIFF_FILE="$ktlint_diff_clean" \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base develop 2>&1)"
code_ktlint_task_failure=$?
assert_eq "1" "$code_ktlint_task_failure" \
  "ktlintCheck タスク自体の実行失敗(rc!=0)は、レポートが(古いまま)クリーンでも 10 にならず 1"
assert_contains "$out_ktlint_task_failure" "lint タスク自体が失敗しました" \
  "タスク自体の実行失敗である旨を stderr に出す"
rm -f "$fake_ktlint_task_fails"

rm -f "$fake_ok" "$fake_ng" "$ktlint_diff_hits" "$ktlint_diff_clean"
rm -rf "$ktlint_report_dir"

# --- I-4: PREFLIGHT_SKIP_KTLINT はゲートを丸ごとスキップするが、それを stderr に
# 目立つ警告として出し、要約行にもスキップしたゲート名を残す（黙って「全ゲート合格」と
# 言わせない）---

fake_ok2="$(make_fake_gradle 0)"
out_skip_warning="$(PREFLIGHT_GRADLE="$fake_ok2" PREFLIGHT_SKIP_KTLINT=1 \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base develop 2>&1)"
code_skip_warning=$?
assert_eq "0" "$code_skip_warning" "PREFLIGHT_SKIP_KTLINT でも他ゲートが成功すれば全体は 0"
assert_contains "$out_skip_warning" "PREFLIGHT_SKIP_KTLINT" "ktlint をスキップしたことを警告する"
assert_contains "$out_skip_warning" "スキップ" "要約行にスキップしたゲートがあることを残す"
rm -f "$fake_ok2"

# --- ゲートを1つも実行していないのに合格と報告しない（fail-open を塞ぐ） ---

# 設定ファイルがあるのにゲートが 0 個 = 設定とローダーの取り決めが噛み合っていない。
# 「何も検証していないのに緑」を防ぐため実行エラー(1)で落とす。
EMPTY_CONFIG_REPO="$(mktemp -d)"
git -C "$EMPTY_CONFIG_REPO" init -q .
mkdir -p "$EMPTY_CONFIG_REPO/.claude"
printf 'GH_FIX_ISSUE_BASE_BRANCH="main"\n' > "$EMPTY_CONFIG_REPO/.claude/gh-fix-issue.config.sh"

out_empty_config="$(cd "$EMPTY_CONFIG_REPO" && bash "$SCRIPTS_DIR/preflight-gates.sh" --base main 2>&1)"
empty_config_rc=$?
assert_eq "1" "$empty_config_rc" "設定はあるのにゲートが0個なら合格にせず exit 1"
assert_contains "$out_empty_config" "実行できるゲートが 1 つもありませんでした" \
  "ゲートが0個である理由を stderr に出す"
rm -rf "$EMPTY_CONFIG_REPO"

# 設定ファイル自体が無いリポジトリは「ゲートを使わない」という選択なので 0 で通す。
# ただし何も検証していないことは必ず知らせる。
NO_CONFIG_REPO="$(mktemp -d)"
git -C "$NO_CONFIG_REPO" init -q .
out_no_config="$(cd "$NO_CONFIG_REPO" && bash "$SCRIPTS_DIR/preflight-gates.sh" --base main 2>&1)"
no_config_rc=$?
assert_eq "0" "$no_config_rc" "設定ファイルが無いリポジトリは 0（ゲートを使わない選択）"
assert_contains "$out_no_config" "ゲートが設定されていないため" \
  "ゲート未設定でも「何も実行していない」ことを警告する"
rm -rf "$NO_CONFIG_REPO"

# 通過時の要約に実行件数が出る（0件を見逃さないため）
# 先行テストで $fake_ok は削除済みなので、ここで作り直す
fake_ok_count="$(make_fake_gradle 0)"
out_count="$(PREFLIGHT_GRADLE="$fake_ok_count" PREFLIGHT_SKIP_KTLINT=1 \
  bash "$SCRIPTS_DIR/preflight-gates.sh" --base develop 2>&1)"
assert_contains "$out_count" "実行したゲート: 2 件" "要約に実行したゲート数を出す"
rm -f "$fake_ok_count"

# --- リポジトリ側 .claude/gh-fix-issue.gates.sh への委譲 ---
#
# 上書きファイルはプラグインごとに独立（.claude/<プラグイン名>.gates.sh）。
# .claude/gh-fix-issue.gates.sh があるリポジトリでは、gh-fix-issue.config.sh のゲート定義よりも
# 優先して委譲し、終了コードをそのまま返す（契約は同じ 0 / 10 / 1）。

make_gates_repo() {
  local rc="$1"
  local repo
  repo="$(mktemp -d)"
  git -C "$repo" init -q .
  mkdir -p "$repo/.claude"
  # config も併置して、gates.sh が config より優先されることを検証する。
  # このゲートが実行されたら（＝委譲されなかったら）exit 1 で気づけるようにする。
  printf 'GH_FIX_ISSUE_GATES="$(printf '"'"'config-gate\\tfalse'"'"')"\n' \
    > "$repo/.claude/gh-fix-issue.config.sh"
  cat > "$repo/.claude/gh-fix-issue.gates.sh" <<EOF
#!/usr/bin/env bash
echo "delegated-gate-ran"
exit $rc
EOF
  printf '%s\n' "$repo"
}

for rc in 0 10 1; do
  GATES_REPO="$(make_gates_repo "$rc")"
  out_gates="$(cd "$GATES_REPO" && bash "$SCRIPTS_DIR/preflight-gates.sh" --base main 2>&1)"
  gates_rc=$?
  assert_eq "$rc" "$gates_rc" ".claude/gh-fix-issue.gates.sh の exit $rc をそのまま返す"
  assert_contains "$out_gates" "delegated-gate-ran" \
    ".claude/gh-fix-issue.gates.sh が実行される (exit $rc)"
  rm -rf "$GATES_REPO"
done

GATES_REPO="$(make_gates_repo 0)"
out_gates_priority="$(cd "$GATES_REPO" && bash "$SCRIPTS_DIR/preflight-gates.sh" --base main 2>&1)"
assert_contains "$out_gates_priority" "委譲" \
  "委譲したことを出力に明示する"
case "$out_gates_priority" in
  *config-gate*)
    FAIL=$((FAIL + 1)); echo "  FAIL .claude/gh-fix-issue.gates.sh がある場合は config のゲートを実行しない" ;;
  *)
    PASS=$((PASS + 1)); echo "  ok   .claude/gh-fix-issue.gates.sh がある場合は config のゲートを実行しない" ;;
esac
rm -rf "$GATES_REPO"

# 他プラグインの上書きファイル（gh-fix-review.gates.sh）には反応しない。
# プラグイン間の独立性の要：片方のプラグイン用に置いた定義が、もう片方の動作を変えない。
OTHER_PLUGIN_REPO="$(mktemp -d)"
git -C "$OTHER_PLUGIN_REPO" init -q .
mkdir -p "$OTHER_PLUGIN_REPO/.claude"
printf 'GH_FIX_ISSUE_GATES="$(printf '"'"'config-gate\\ttrue'"'"')"\n' \
  > "$OTHER_PLUGIN_REPO/.claude/gh-fix-issue.config.sh"
cat > "$OTHER_PLUGIN_REPO/.claude/gh-fix-review.gates.sh" <<'EOF'
#!/usr/bin/env bash
echo "other-plugin-gate-ran"
exit 1
EOF
out_other="$(cd "$OTHER_PLUGIN_REPO" && bash "$SCRIPTS_DIR/preflight-gates.sh" --base main 2>&1)"
other_rc=$?
assert_eq "0" "$other_rc" "gh-fix-review.gates.sh があっても委譲せず config のゲートで判定する"
case "$out_other" in
  *other-plugin-gate-ran*)
    FAIL=$((FAIL + 1)); echo "  FAIL 他プラグインの上書きファイルを実行しない" ;;
  *)
    PASS=$((PASS + 1)); echo "  ok   他プラグインの上書きファイルを実行しない" ;;
esac
rm -rf "$OTHER_PLUGIN_REPO"

# 一時リポジトリから出て後始末する
cd "$PREFLIGHT_ORIG_PWD" || true
rm -rf "$PREFLIGHT_FIXTURE_REPO"
