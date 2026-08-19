run_ktlint_diff() {
  node "$SCRIPTS_DIR/ktlint-diff.mjs" \
    --report-dir "$TESTS_DIR/fixtures" \
    --diff-file "$TESTS_DIR/fixtures/sample.diff" \
    --repo-root "/repo" 2>&1
}

out="$(run_ktlint_diff)"
code=$?

assert_eq "10" "$code" "追加行に違反があれば 10"
assert_contains "$out" "Changed.kt:12" "追加行(12)の違反は報告する"

case "$out" in
  *"Changed.kt:99"*) assert_eq "報告しない" "報告した" "追加行外(99)の違反は報告しない" ;;
  *) assert_eq "報告しない" "報告しない" "追加行外(99)の違反は報告しない" ;;
esac

case "$out" in
  *"Untouched.kt"*) assert_eq "報告しない" "報告した" "変更していないファイルの違反は報告しない" ;;
  *) assert_eq "報告しない" "報告しない" "変更していないファイルの違反は報告しない" ;;
esac

# --report-dir が存在しない/空 -> レポート未検出として exit 1
out_missing_report_dir="$(node "$SCRIPTS_DIR/ktlint-diff.mjs" \
  --report-dir "$TESTS_DIR/fixtures/does-not-exist" \
  --diff-file "$TESTS_DIR/fixtures/sample.diff" \
  --repo-root "/repo" 2>&1)"
code_missing_report_dir=$?

assert_eq "1" "$code_missing_report_dir" "存在しない --report-dir は exit 1"
assert_contains "$out_missing_report_dir" "ktlint レポートが見つかりません" "レポート未検出の旨を stderr に出す"

# --repo-root が checkstyle の絶対パスと噛み合わない -> 照合不能として exit 1（偽陰性グリーンを防ぐ）
out_wrong_repo_root="$(node "$SCRIPTS_DIR/ktlint-diff.mjs" \
  --report-dir "$TESTS_DIR/fixtures" \
  --diff-file "$TESTS_DIR/fixtures/sample.diff" \
  --repo-root "/wrong" 2>&1)"
code_wrong_repo_root=$?

assert_eq "1" "$code_wrong_repo_root" "--repo-root が噛み合わないと exit 1"
assert_contains "$out_wrong_repo_root" "repo-root を確認してください" "--repo-root を確認せよと stderr に出す"

# 正当なクリーンケース: report-dir/repo-root は正しいが、追加行に違反が無い -> exit 0
out_clean="$(node "$SCRIPTS_DIR/ktlint-diff.mjs" \
  --report-dir "$TESTS_DIR/fixtures" \
  --diff-file "$TESTS_DIR/fixtures/sample-clean.diff" \
  --repo-root "/repo" 2>&1)"
code_clean=$?

assert_eq "0" "$code_clean" "正しい report-dir/repo-root で追加行に違反が無ければ 0（誤検知しない）"

# 退行防止(Fix Round 2): diff が空（追加行が1行も無い）でも、
# --repo-root が正しければ誤って repo-root 不整合と判定してはいけない -> exit 0
out_empty_diff="$(node "$SCRIPTS_DIR/ktlint-diff.mjs" \
  --report-dir "$TESTS_DIR/fixtures" \
  --diff-file "$TESTS_DIR/fixtures/empty.diff" \
  --repo-root "/repo" 2>&1)"
code_empty_diff=$?

assert_eq "0" "$code_empty_diff" "diff が空でも --repo-root が正しければ 0（誤って repo-root 不整合としない）"

# 退行防止(Fix Round 2): レポートに載っていないファイル（Kotlin 以外）だけを触る diff でも、
# --repo-root が正しければ誤って repo-root 不整合と判定してはいけない -> exit 0
out_docs_only_diff="$(node "$SCRIPTS_DIR/ktlint-diff.mjs" \
  --report-dir "$TESTS_DIR/fixtures" \
  --diff-file "$TESTS_DIR/fixtures/sample-docs-only.diff" \
  --repo-root "/repo" 2>&1)"
code_docs_only_diff=$?

assert_eq "0" "$code_docs_only_diff" "レポートに無いファイルだけの diff でも --repo-root が正しければ 0（誤って repo-root 不整合としない）"
