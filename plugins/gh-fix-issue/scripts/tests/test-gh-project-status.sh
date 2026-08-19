# gh-project-status.sh のテスト。
# fixture を注入するため GitHub API は一切呼ばない（--dry-run で解決結果だけを見る）。

run_status() {
  local project="$1" status="$2"
  GH_PROJECT_ITEMS_FIXTURE="$TESTS_DIR/fixtures/gh-project-items.json" \
    GH_PROJECT_FIELDS_FIXTURE="$TESTS_DIR/fixtures/gh-project-fields.json" \
    bash "$SCRIPTS_DIR/gh-project-status.sh" \
      --issue 3462 --project "$project" --status "$status" --dry-run 2>&1
}

out="$(run_status "Android Issues" "🏗 In progress")"
code=$?
assert_eq "0" "$code" "正しい Project 名と Status 名なら 0"
assert_contains "$out" "item=PVTI_androidissues_item" "所属する Project のアイテムを選ぶ"
assert_contains "$out" "option=opt_inprogress" "指定した Status の選択肢 ID を解決する"

# Android Issues は "🏗 In progress"、Android Pull Requests は "In Progress" と表記が違う。
# 絵文字と大小文字を無視して照合できないと、片方でしか動かないスクリプトになる。
out="$(run_status "Android Issues" "In Progress")"
assert_eq "0" "$?" "絵文字なし・大小文字違いでも解決できる"
assert_contains "$out" "option=opt_inprogress" "揺れを吸収して同じ選択肢に解決する"

out="$(run_status "Android Issues" "💮 Reviewed")"
assert_contains "$out" "option=opt_reviewed" "Reviewed も解決できる"

# 所属していない Project を指定したら、黙って別の Project を触らずに落ちること
out="$(run_status "Android Pull Requests" "In Progress")"
assert_eq "1" "$?" "所属していない Project 名なら 1"
assert_contains "$out" "登録されていません" "所属していない旨を出す"
assert_contains "$out" "Android Issues" "実際の所属先を出して原因を追えるようにする"

out="$(run_status "Android Issues" "存在しないStatus")"
assert_eq "1" "$?" "存在しない Status 名なら 1"
assert_contains "$out" "選択肢" "利用可能な選択肢を出す"

out="$(GH_PROJECT_ITEMS_FIXTURE="$TESTS_DIR/fixtures/gh-project-items.json" \
  GH_PROJECT_FIELDS_FIXTURE="$TESTS_DIR/fixtures/gh-project-fields.json" \
  bash "$SCRIPTS_DIR/gh-project-status.sh" \
    --issue abc --project "Android Issues" --status "🏗 In progress" --dry-run 2>&1)"
assert_eq "1" "$?" "番号が非数値なら 1"

out="$(bash "$SCRIPTS_DIR/gh-project-status.sh" --issue 1 --project "X" 2>&1)"
assert_eq "1" "$?" "--status を省略したら usage で 1"

# --dry-run は解決した時点で return するため、成功時のメッセージ出力を通らない。
# そこに全角文字直前の未囲み変数があり、実 API 実行時だけ unbound variable で落ちた。
# fixture 使用時は mutation を飛ばして、この経路を最後まで通す。
out="$(GH_PROJECT_ITEMS_FIXTURE="$TESTS_DIR/fixtures/gh-project-items.json" \
  GH_PROJECT_FIELDS_FIXTURE="$TESTS_DIR/fixtures/gh-project-fields.json" \
  bash "$SCRIPTS_DIR/gh-project-status.sh" \
    --issue 3462 --project "Android Issues" --status "💮 Reviewed" 2>&1)"
assert_eq "0" "$?" "dry-run でない経路も最後まで通る"
assert_contains "$out" "Android Issues の Status を「💮 Reviewed」に設定しました (#3462)" "成功メッセージが壊れずに出る"

# gh の引数そのものを検証する。GraphQL の String!/ID! を -F で渡すと、gh が
# 「全桁数字の文字列」を Int に変換してしまい、option ID がたまたま全数字だと
# mutation が型エラーで落ちる。実 API でしか踏めないので、モックで固定する。
mock_gh="$(mktemp)"
argv_log="$(mktemp)"
cat > "$mock_gh" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "auth" ]; then echo "Token scopes: 'repo', 'project'"; exit 0; fi
printf '%s\n' "\$*" >> "$argv_log"
echo '{"data":{}}'
MOCK
chmod +x "$mock_gh"

GH_PROJECT_ITEMS_FIXTURE="$TESTS_DIR/fixtures/gh-project-items.json" \
  GH_PROJECT_FIELDS_FIXTURE="$TESTS_DIR/fixtures/gh-project-fields.json" \
  GH_BIN="$mock_gh" \
  bash "$SCRIPTS_DIR/gh-project-status.sh" \
    --issue 3462 --project "Android Issues" --status "💮 Reviewed" >/dev/null 2>&1
assert_eq "0" "$?" "モック gh でも mutation まで到達して 0"

mutation_argv="$(cat "$argv_log")"
assert_contains "$mutation_argv" "-f option=opt_reviewed" "option は -f で渡す（-F だと全数字IDがIntに変換される）"
assert_contains "$mutation_argv" "-f project=PVT_androidissues" "project も -f で渡す"
assert_contains "$mutation_argv" "-f item=PVTI_androidissues_item" "item も -f で渡す"
assert_contains "$mutation_argv" "-f field=PVTSSF_status" "field も -f で渡す"

case "$mutation_argv" in
  *"-F option="*|*"-F project="*|*"-F item="*|*"-F field="*)
    assert_eq "-F を使わない" "-F を使っている" "String!/ID! に -F を使っていない" ;;
  *) assert_eq "-F を使わない" "-F を使わない" "String!/ID! に -F を使っていない" ;;
esac

rm -f "$mock_gh" "$argv_log"

# 正規化が空文字に潰れる入力で、意図しない選択肢が選ばれないこと
out="$(run_status "Android Issues" "🏗")"
assert_eq "1" "$?" "絵文字だけの Status 指定は一致させない"

out="$(GH_PROJECT_ITEMS_FIXTURE="$TESTS_DIR/fixtures/gh-project-items.json" \
  bash "$SCRIPTS_DIR/gh-project-status.sh" --issue 1 --project "X" --status "Y" --unknown 2>&1)"
assert_eq "1" "$?" "不明な引数は 1"
assert_contains "$out" "不明な引数" "不明な引数である旨を出す"

out="$(GH_PROJECT_ITEMS_FIXTURE="$TESTS_DIR/fixtures/gh-project-items.json" \
  bash "$SCRIPTS_DIR/gh-project-status.sh" --issue 3462 --project 2>&1)"
assert_eq "1" "$?" "値の無いフラグは 1"
assert_contains "$out" "値が必要です" "どのフラグに値が要るかを出す"
