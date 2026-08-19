# 引数パースの検証。gh は呼ばれない。

out="$(bash "$SKILL_DIR/pr-reply.sh" 2>&1)"; code=$?
assert_eq "1" "$code" "モード未指定は 1"
assert_contains "$out" "モードを指定してください" "モード未指定のメッセージ"

out="$(bash "$SKILL_DIR/pr-reply.sh" --nope 2>&1)"; code=$?
assert_eq "1" "$code" "不明な引数は 1"
assert_contains "$out" "不明な引数" "不明な引数のメッセージ"

out="$(bash "$SKILL_DIR/pr-reply.sh" --list --verify 2>&1)"; code=$?
assert_eq "1" "$code" "モード二重指定は 1"
assert_contains "$out" "モードは1つだけ" "モード二重指定のメッセージ"

out="$(bash "$SKILL_DIR/pr-reply.sh" --reply 2>&1)"; code=$?
assert_eq "1" "$code" "--reply に id が無いと 1"
assert_contains "$out" "comment_id が必要です" "--reply の id 欠落メッセージ"

out="$(bash "$SKILL_DIR/pr-reply.sh" --pr 2>&1)"; code=$?
assert_eq "1" "$code" "--pr に値が無いと 1"

out="$(bash "$SKILL_DIR/pr-reply.sh" --reply 123 2>&1)"; code=$?
assert_eq "1" "$code" "--body-file 無しの --reply は 1"
assert_contains "$out" "--body-file が必要です" "--body-file 欠落メッセージ"
