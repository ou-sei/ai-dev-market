# threads.jq の判定を検証する。gh は呼ばれない。

FX="$FIXTURES_DIR/comments-basic.json"

ids="$(jq --arg self "ou-sei" -f "$SKILL_DIR/threads.jq" "$FX" | jq -c '[.[].thread_root_id]')"
assert_eq "[3,7,8,11]" "$ids" "未返信スレッドは 3/7/8/11 の4件"

count="$(jq --arg self "ou-sei" -f "$SKILL_DIR/threads.jq" "$FX" | jq 'length')"
assert_eq "4" "$count" "件数は4"

has6="$(jq --arg self "ou-sei" -f "$SKILL_DIR/threads.jq" "$FX" | jq '[.[].thread_root_id] | contains([6])')"
assert_eq "false" "$has6" "起点が自分のスレッド(6)は対象外"

has1="$(jq --arg self "ou-sei" -f "$SKILL_DIR/threads.jq" "$FX" | jq '[.[].thread_root_id] | contains([1])')"
assert_eq "false" "$has1" "最新が自分のスレッド(1)は返信済み"

outdated="$(jq --arg self "ou-sei" -f "$SKILL_DIR/threads.jq" "$FX" | jq -c '.[] | select(.thread_root_id == 11) | {outdated, line}')"
assert_eq '{"outdated":true,"line":60}' "$outdated" "outdated は true、line は original_line にフォールバック"

chain="$(jq --arg self "ou-sei" -f "$SKILL_DIR/threads.jq" "$FX" | jq -c '.[] | select(.thread_root_id == 8) | .comments | length')"
assert_eq "3" "$chain" "in_reply_to が直前を指しても起点8に3件集約される"

lastb="$(jq --arg self "ou-sei" -f "$SKILL_DIR/threads.jq" "$FX" | jq -r '.[] | select(.thread_root_id == 3) | .last_author')"
assert_eq "claude[bot]" "$lastb" "自分の返信後の追記で last_author が相手になる"

# 自分が別人なら結果が変わること（$self が効いていることの確認）
other="$(jq --arg self "claude[bot]" -f "$SKILL_DIR/threads.jq" "$FX" | jq -c '[.[].thread_root_id]')"
assert_eq "[6,7]" "$other" "self が claude[bot] のときは起点が自分の 1/3/8/11 が除外され 6 と 7 が残る"
