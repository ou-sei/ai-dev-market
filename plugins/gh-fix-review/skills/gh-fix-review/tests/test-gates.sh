# gates.sh の検証。実 GitHub もビルドツールも呼ばず、一時 git リポジトリで
# 「委譲 → 検出 → 警告して続行」の 3 段階の分岐だけを確かめる。
#
# run-tests.sh から source される前提（assert_eq / assert_contains / SKILL_DIR を使う）。

GATES="$SKILL_DIR/gates.sh"

# --- 段階 1: <repo-root>/.claude/gh-fix-review.gates.sh があれば委譲し、終了コードをそのまま返す ---
#
# 上書きファイルはプラグインごとに独立（.claude/<プラグイン名>.gates.sh）。
# 他のプラグイン用のファイルには反応しない。

make_gates_override_repo() {
  local rc="$1"
  local repo
  repo="$(mktemp -d)"
  git -C "$repo" init -q .
  mkdir -p "$repo/.claude"
  cat > "$repo/.claude/gh-fix-review.gates.sh" <<EOF
#!/usr/bin/env bash
echo "delegated-gate-ran"
exit $rc
EOF
  printf '%s\n' "$repo"
}

for rc in 0 10 1; do
  override_repo="$(make_gates_override_repo "$rc")"
  out_override="$(cd "$override_repo" && bash "$GATES" 2>&1)"
  override_rc=$?
  assert_eq "$rc" "$override_rc" ".claude/gh-fix-review.gates.sh の exit $rc をそのまま返す"
  assert_contains "$out_override" "delegated-gate-ran" \
    ".claude/gh-fix-review.gates.sh に委譲する (exit $rc)"
  rm -rf "$override_repo"
done

# 他プラグインの上書きファイル（gh-fix-issue.gates.sh）には反応しない。
# プラグイン間の独立性の要：片方のプラグイン用に置いた定義が、もう片方の動作を変えない。
other_plugin_repo="$(mktemp -d)"
git -C "$other_plugin_repo" init -q .
mkdir -p "$other_plugin_repo/.claude"
cat > "$other_plugin_repo/.claude/gh-fix-issue.gates.sh" <<'EOF'
#!/usr/bin/env bash
echo "other-plugin-gate-ran"
exit 1
EOF
out_other="$(cd "$other_plugin_repo" && bash "$GATES" 2>&1)"
other_rc=$?
assert_eq "0" "$other_rc" "gh-fix-issue.gates.sh があっても委譲せず自分の段階 2/3 で判定する"
case "$out_other" in
  *other-plugin-gate-ran*)
    FAIL=$((FAIL + 1)); echo "  FAIL 他プラグインの上書きファイルを実行しない" ;;
  *)
    PASS=$((PASS + 1)); echo "  ok   他プラグインの上書きファイルを実行しない" ;;
esac
rm -rf "$other_plugin_repo"

# --- 段階 2: 検出。gradlew があれば ./gradlew test を実行し、合否を返す ---

make_gradle_repo() {
  local rc="$1"
  local repo
  repo="$(mktemp -d)"
  git -C "$repo" init -q .
  cat > "$repo/gradlew" <<EOF
#!/usr/bin/env bash
echo "fake gradle: \$*"
exit $rc
EOF
  chmod +x "$repo/gradlew"
  printf '%s\n' "$repo"
}

gradle_ok_repo="$(make_gradle_repo 0)"
out_gradle_ok="$(cd "$gradle_ok_repo" && bash "$GATES" 2>&1)"
gradle_ok_rc=$?
assert_eq "0" "$gradle_ok_rc" "検出した gradlew test が成功すれば 0"
assert_contains "$out_gradle_ok" "gradlew test" "検出したゲート名を出力する"
rm -rf "$gradle_ok_repo"

gradle_ng_repo="$(make_gradle_repo 1)"
out_gradle_ng="$(cd "$gradle_ng_repo" && bash "$GATES" 2>&1)"
gradle_ng_rc=$?
assert_eq "10" "$gradle_ng_rc" "検出した gradlew test が失敗すれば 10（不合格）"
rm -rf "$gradle_ng_repo"

# --- 段階 3: 検出できなければ警告して 0 を返す（黙って通さない） ---

empty_repo="$(mktemp -d)"
git -C "$empty_repo" init -q .
out_empty="$(cd "$empty_repo" && bash "$GATES" 2>&1)"
empty_rc=$?
assert_eq "0" "$empty_rc" "検出できないリポジトリでは 0 で続行する"
assert_contains "$out_empty" "検証コマンドを判別できませんでした" \
  "何も検証していないことを警告する"
rm -rf "$empty_repo"

# --- git リポジトリの外では実行基盤の問題として 1 を返す ---

not_a_repo="$(mktemp -d)"
out_not_repo="$(cd "$not_a_repo" && bash "$GATES" 2>&1)"
not_repo_rc=$?
assert_eq "1" "$not_repo_rc" "git リポジトリの外では exit 1（実行基盤の問題）"
rm -rf "$not_a_repo"
