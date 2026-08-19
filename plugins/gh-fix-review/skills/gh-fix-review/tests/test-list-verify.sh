# --list / --verify を fixture 経由で検証する。gh は呼ばれない。

FX="$FIXTURES_DIR/comments-basic.json"

out="$(PR_REPLY_FIXTURE="$FX" PR_REPLY_SELF="ou-sei" bash "$SKILL_DIR/pr-reply.sh" --list 2>/dev/null)"
assert_eq "[3,7,8,11]" "$(printf '%s' "$out" | jq -c '[.[].thread_root_id]')" "--list が未返信4件を返す"

warn="$(PR_REPLY_FIXTURE="$FX" PR_REPLY_SELF="ou-sei" bash "$SKILL_DIR/pr-reply.sh" --list 2>&1 >/dev/null)"
assert_contains "$warn" "実際の GitHub では検証されていません" "fixture 使用時に警告が出る"

PR_REPLY_FIXTURE="$FX" PR_REPLY_SELF="ou-sei" bash "$SKILL_DIR/pr-reply.sh" --verify >/dev/null 2>&1
assert_eq "10" "$?" "未返信ありで --verify は 10"

err="$(PR_REPLY_FIXTURE="$FX" PR_REPLY_SELF="ou-sei" bash "$SKILL_DIR/pr-reply.sh" --verify 2>&1 >/dev/null)"
assert_contains "$err" "未返信スレッドが 4 件" "件数が stderr に出る"
assert_contains "$err" "b.kt:20" "該当箇所が stderr に出る"

# self を claude[bot] に変えると未返信は2件（6と7）になり、依然として --verify は 10
PR_REPLY_FIXTURE="$FX" PR_REPLY_SELF="claude[bot]" bash "$SKILL_DIR/pr-reply.sh" --verify >/dev/null 2>&1
assert_eq "10" "$?" "self を変えると未返信2件で 10"

echo '[]' > "$TESTS_DIR/fixtures/comments-empty.json"
PR_REPLY_FIXTURE="$TESTS_DIR/fixtures/comments-empty.json" PR_REPLY_SELF="ou-sei" bash "$SKILL_DIR/pr-reply.sh" --verify >/dev/null 2>&1
assert_eq "0" "$?" "コメント0件なら --verify は 0"
rm -f "$TESTS_DIR/fixtures/comments-empty.json"

# gh の失敗を「未返信なし」として通さないこと。fixture の読み取り失敗で同じ経路を踏む。
PR_REPLY_FIXTURE="/nonexistent/comments.json" PR_REPLY_SELF="ou-sei" bash "$SKILL_DIR/pr-reply.sh" --verify >/dev/null 2>&1
assert_eq "30" "$?" "コメント一覧を取得できないときは 30（未返信ゼロで通さない）"

# GitHub のエラー応答を掴んだときに架空のスレッドをでっち上げないこと。
printf '[{"message":"Not Found","status":"404"}]' > "$TESTS_DIR/fixtures/comments-error.json"
PR_REPLY_FIXTURE="$TESTS_DIR/fixtures/comments-error.json" PR_REPLY_SELF="ou-sei" bash "$SKILL_DIR/pr-reply.sh" --verify >/dev/null 2>&1
assert_eq "30" "$?" "GitHub のエラー応答を掴んだときは 30"
rm -f "$TESTS_DIR/fixtures/comments-error.json"

# self を変えたときに終了コードだけでなく対象スレッドの中身も確かめる。
other="$(PR_REPLY_FIXTURE="$FX" PR_REPLY_SELF="claude[bot]" bash "$SKILL_DIR/pr-reply.sh" --list 2>/dev/null | jq -c '[.[].thread_root_id]')"
assert_eq "[6,7]" "$other" "self=claude[bot] の対象は起点が自分でない 6 と 7"

# --reply のガードは gh を呼ぶ前に走るので、実 GitHub 無しで検証できる。
bash "$SKILL_DIR/pr-reply.sh" --reply 123 --body-file /nonexistent/body.md >/dev/null 2>&1
assert_eq "1" "$?" "--reply の本文ファイルが無ければ 1"

: > "$TESTS_DIR/fixtures/empty-body.md"
bash "$SKILL_DIR/pr-reply.sh" --reply 123 --body-file "$TESTS_DIR/fixtures/empty-body.md" >/dev/null 2>&1
assert_eq "1" "$?" "--reply の本文ファイルが空なら 1"
rm -f "$TESTS_DIR/fixtures/empty-body.md"
