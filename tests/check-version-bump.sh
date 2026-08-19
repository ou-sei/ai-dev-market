#!/usr/bin/env bash
# 変更のあったプラグインの plugin.json の version が上がっているか検証する。
#
#   bash tests/check-version-bump.sh <base-sha>
#
# 終了コード: 0 = 問題なし / 1 = version が据え置き / 2 = 実行失敗
#
# 配布は main へのマージで起きる（docs/plugin-distribution.md §6）。version が
# 動かないと利用者側のキャッシュが更新されない可能性があるため機械的に見る。
set -uo pipefail

BASE="${1:-}"
if [ -z "$BASE" ]; then
  echo "base-sha を指定してください。" >&2
  exit 2
fi

if ! git cat-file -e "$BASE^{commit}" 2>/dev/null; then
  echo "base-sha が見つかりません: $BASE" >&2
  exit 2
fi

read_version() {
  python3 -c 'import json,io,sys; print(json.load(io.open(sys.argv[1])).get("version",""))' "$1" 2>/dev/null
}

status=0
for dir in plugins/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  manifest="$dir.claude-plugin/plugin.json"
  [ -f "$manifest" ] || continue

  # そのプラグイン配下に変更が無ければ見ない
  if git diff --quiet "$BASE" -- "$dir"; then
    continue
  fi

  old=""
  if git cat-file -e "$BASE:$manifest" 2>/dev/null; then
    old="$(git show "$BASE:$manifest" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null)"
  fi
  new="$(read_version "$manifest")"

  # base に無い = 新規プラグイン。据え置きの判定対象にしない
  if [ -z "$old" ]; then
    echo "新規: plugins/$name (version $new)"
    continue
  fi

  if [ "$old" = "$new" ]; then
    echo "plugins/$name に変更がありますが version が $new のままです。" >&2
    status=1
  else
    echo "OK: plugins/$name $old -> $new"
  fi
done

if [ "$status" -ne 0 ]; then
  echo >&2
  echo "plugin.json の version を上げてください。" >&2
fi
exit "$status"
