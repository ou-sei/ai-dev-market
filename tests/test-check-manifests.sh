#!/usr/bin/env bash
# check-manifests.py の検証。実際のリポジトリは汚さず、一時ディレクトリに壊れた
# 構成を作って終了コードを確かめる。
#
#   bash tests/test-check-manifests.sh
#
# 終了コード: 0 = 全件通過 / 1 = 1件以上失敗
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/tests/check-manifests.py"
PASS=0
FAIL=0

assert_exit() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); echo "  ok   $msg"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $msg (expected=$expected actual=$actual)"
  fi
}

# 正しい構成を組み立てる
make_tree() {
  local root="$1"
  mkdir -p "$root/.claude-plugin" "$root/plugins/alpha/.claude-plugin" "$root/plugins/beta/.claude-plugin"
  cat > "$root/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "ai-dev-market",
  "owner": { "name": "example-owner" },
  "plugins": [
    { "name": "alpha", "version": "1.0.0", "source": "./plugins/alpha" },
    { "name": "beta",  "version": "2.0.0", "source": "./plugins/beta" }
  ]
}
JSON
  printf '{"name":"alpha","version":"1.0.0"}\n' > "$root/plugins/alpha/.claude-plugin/plugin.json"
  printf '{"name":"beta","version":"2.0.0"}\n'  > "$root/plugins/beta/.claude-plugin/plugin.json"
}

T="$(mktemp -d)"

make_tree "$T/ok"
python3 "$CHECK" "$T/ok" >/dev/null 2>&1
assert_exit "0" "$?" "整合している構成は 0"

make_tree "$T/unregistered"
mkdir -p "$T/unregistered/plugins/gamma/.claude-plugin"
printf '{"name":"gamma","version":"1.0.0"}\n' > "$T/unregistered/plugins/gamma/.claude-plugin/plugin.json"
python3 "$CHECK" "$T/unregistered" >/dev/null 2>&1
assert_exit "1" "$?" "未登録のプラグインディレクトリがあれば 1"

make_tree "$T/missing"
rm -rf "$T/missing/plugins/beta"
python3 "$CHECK" "$T/missing" >/dev/null 2>&1
assert_exit "1" "$?" "参照先ディレクトリが無ければ 1"

make_tree "$T/nomanifest"
rm -f "$T/nomanifest/plugins/beta/.claude-plugin/plugin.json"
python3 "$CHECK" "$T/nomanifest" >/dev/null 2>&1
assert_exit "1" "$?" "plugin.json が無ければ 1"

make_tree "$T/badversion"
printf '{"name":"beta","version":"9.9.9"}\n' > "$T/badversion/plugins/beta/.claude-plugin/plugin.json"
python3 "$CHECK" "$T/badversion" >/dev/null 2>&1
assert_exit "1" "$?" "marketplace と plugin.json の version 不一致は 1"

make_tree "$T/badname"
printf '{"name":"BETA","version":"2.0.0"}\n' > "$T/badname/plugins/beta/.claude-plugin/plugin.json"
python3 "$CHECK" "$T/badname" >/dev/null 2>&1
assert_exit "1" "$?" "marketplace と plugin.json の name 不一致は 1"

make_tree "$T/broken"
printf 'not json\n' > "$T/broken/.claude-plugin/marketplace.json"
python3 "$CHECK" "$T/broken" >/dev/null 2>&1
assert_exit "2" "$?" "marketplace.json が壊れていれば 2（実行失敗）"

python3 "$CHECK" "$REPO_ROOT" >/dev/null 2>&1
assert_exit "0" "$?" "実際の ai-dev-market が整合している"

rm -rf "$T"
echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
