#!/usr/bin/env bash
# gh-fix-review skill のテストを実行する。tests/test-*.sh を順に読み込み、通過数と失敗数を集計する。
#
#   bash ~/.claude/skills/gh-fix-review/tests/run-tests.sh
#
# 終了コード: 0 = 全件通過 / 1 = 1件以上失敗
#
# bats は使わない。ヘルパは assert_eq と assert_contains の2つだけ。
# 実 GitHub は呼ばない（PR_REPLY_FIXTURE と PR_REPLY_SELF で経路を再現する）。
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURES_DIR="$TESTS_DIR/fixtures"
export TESTS_DIR SKILL_DIR FIXTURES_DIR

PASS=0
FAIL=0

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ok   $msg"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $msg"
    echo "         expected: $expected"
    echo "         actual:   $actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  case "$haystack" in
    *"$needle"*)
      PASS=$((PASS + 1))
      echo "  ok   $msg"
      ;;
    *)
      FAIL=$((FAIL + 1))
      echo "  FAIL $msg"
      echo "         expected to contain: $needle"
      echo "         actual:              $haystack"
      ;;
  esac
}

for test_file in "$TESTS_DIR"/test-*.sh; do
  [ -f "$test_file" ] || continue
  echo "== $(basename "$test_file")"
  # shellcheck disable=SC1090
  . "$test_file"
done

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
