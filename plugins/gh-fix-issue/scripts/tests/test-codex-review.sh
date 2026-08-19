# --check: CODEX_COMPANION が存在するファイルを指していれば 0
fake_companion="$(mktemp)"
CODEX_COMPANION="$fake_companion" bash "$SCRIPTS_DIR/codex-review.sh" --check >/dev/null 2>&1
assert_eq "0" "$?" "--check returns 0 when CODEX_COMPANION points to an existing file"
rm -f "$fake_companion"

# --check: 存在しないパスなら 30
CODEX_COMPANION="/nonexistent/codex-companion.mjs" \
  CODEX_REVIEW_DISABLE_GLOB=1 \
  bash "$SCRIPTS_DIR/codex-review.sh" --check >/dev/null 2>&1
assert_eq "30" "$?" "--check returns 30 when companion is missing"

# findings は GH_FIX_ISSUE_FINDINGS_DIR で本番の .git/gh-fix-issue/ から隔離する。
# これが無いと、このテストスイートが本番の findings ファイルを実際に上書きしてしまう
# （carried-forward 項目 2 / I-2 で修正した衝突）。
GH_FIX_ISSUE_TEST_FINDINGS_DIR="$(mktemp -d)"

run_round() {
  local fixture="$1" round="${2:-1}"
  CODEX_REVIEW_FIXTURE="$TESTS_DIR/fixtures/$fixture" \
    CODEX_COMPANION="/dev/null" \
    GH_FIX_ISSUE_FINDINGS_DIR="$GH_FIX_ISSUE_TEST_FINDINGS_DIR" \
    bash "$SCRIPTS_DIR/codex-review.sh" --round "$round" --base develop >/dev/null 2>&1
  echo $?
}

assert_eq "0" "$(run_round review-clean.json)" "findings が空なら 0"
assert_eq "10" "$(run_round review-must-fix.json)" "high が 1 件なら 10"
assert_eq "0" "$(run_round review-nested.json)" "medium/low のみなら 0（ネストしていても抽出できる）"

out="$(CODEX_REVIEW_FIXTURE="$TESTS_DIR/fixtures/review-must-fix.json" \
  CODEX_COMPANION="/dev/null" \
  GH_FIX_ISSUE_FINDINGS_DIR="$GH_FIX_ISSUE_TEST_FINDINGS_DIR" \
  bash "$SCRIPTS_DIR/codex-review.sh" --round 1 --base develop 2>&1)"
assert_contains "$out" "Apollo 生成型への非 null 前提アクセス" "対応必須の指摘を標準出力に出す"
assert_contains "$out" "変数名が曖昧" "任意の指摘も標準出力に出す"

# CODEX_REVIEW_FIXTURE 使用時は「Codex を呼ばず fixture を返している」ことを stderr に警告する(I-4)
assert_contains "$out" "CODEX_REVIEW_FIXTURE" "fixture バイパスを使ったことを警告する"

# --round に非数値を渡すと上限チェックを素通りせず usage エラーで 1
CODEX_COMPANION="/dev/null" bash "$SCRIPTS_DIR/codex-review.sh" --round foo --base develop >/dev/null 2>&1
assert_eq "1" "$?" "--round に非数値を渡すと usage エラーで 1"

# findings-<round>.json が GH_FIX_ISSUE_FINDINGS_DIR（テストでは隔離した一時ディレクトリ）に永続化される
findings_file="$GH_FIX_ISSUE_TEST_FINDINGS_DIR/findings-1.json"
rm -f "$findings_file"
run_round review-must-fix.json 1 >/dev/null
assert_eq "true" "$([ -f "$findings_file" ] && echo true || echo false)" "findings-1.json が書き出される"

findings_shape="$(node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const ok = typeof data.verdict === "string" && Array.isArray(data.findings) && data.findings.length === 2;
process.stdout.write(ok ? "true" : "false");
' "$findings_file" 2>/dev/null)"
assert_eq "true" "$findings_shape" "findings-1.json に verdict と findings(2件)が含まれる"

assert_eq "20" "$(run_round review-clean.json 5)" "5 周目は fixture が clean でも 20 で拒否する"
assert_eq "0"  "$(run_round review-clean.json 4)" "4 周目は実行できる"
assert_eq "10" "$(run_round review-must-fix.json 4)" "4 周目でも対応必須があれば 10"

# --- I-2: round 1 は findings ディレクトリを消去してから開始する（前回 Issue の残骸を持ち込まない） ---

stale_findings_dir="$(mktemp -d)"
printf '{"verdict":"needs-attention","findings":[{"severity":"high"}]}' \
  > "$stale_findings_dir/findings-3.json"
CODEX_REVIEW_FIXTURE="$TESTS_DIR/fixtures/review-clean.json" \
  CODEX_COMPANION="/dev/null" \
  GH_FIX_ISSUE_FINDINGS_DIR="$stale_findings_dir" \
  bash "$SCRIPTS_DIR/codex-review.sh" --round 1 --base develop >/dev/null 2>&1
assert_eq "false" "$([ -f "$stale_findings_dir/findings-3.json" ] && echo true || echo false)" \
  "round 1 の開始時に前回実行の findings-N.json が消去される"
assert_eq "true" "$([ -f "$stale_findings_dir/findings-1.json" ] && echo true || echo false)" \
  "round 1 自身の findings-1.json は書き出される"
rm -rf "$stale_findings_dir"

# --- I-2: findings ディレクトリの mkdir -p が失敗したら黙って進めず exit 1 ---

blocking_file="$(mktemp)"
CODEX_REVIEW_FIXTURE="$TESTS_DIR/fixtures/review-clean.json" \
  CODEX_COMPANION="/dev/null" \
  GH_FIX_ISSUE_FINDINGS_DIR="$blocking_file/gh-fix-issue" \
  bash "$SCRIPTS_DIR/codex-review.sh" --round 1 --base develop >/dev/null 2>&1
assert_eq "1" "$?" "findings ディレクトリの mkdir -p が失敗すると exit 1"
rm -f "$blocking_file"

# --- I-3: severity が既知集合外の finding は fail-open で「任意」に倒さず対応必須(fail-closed)扱いにする ---

assert_eq "10" "$(run_round review-bad-severity.json)" "severity が既知集合外(blocker)の finding は対応必須(10)扱いになる"

out_bad_severity="$(CODEX_REVIEW_FIXTURE="$TESTS_DIR/fixtures/review-bad-severity.json" \
  CODEX_COMPANION="/dev/null" \
  GH_FIX_ISSUE_FINDINGS_DIR="$GH_FIX_ISSUE_TEST_FINDINGS_DIR" \
  bash "$SCRIPTS_DIR/codex-review.sh" --round 1 --base develop 2>&1)"
assert_contains "$out_bad_severity" "[不明] (対応必須)" "severity 不明の finding は表示上も対応必須と分かる"

# --- I-3: render_review がクラッシュしたら must_fix=0 に埋没させず実行エラー(1)として停止する ---

assert_eq "1" "$(run_round review-malformed-finding.json)" \
  "finding が不正な形で render_review が例外落ちしたら EXIT_ERROR(1)（fail-open の温床を塞ぐ）"

# --- --discuss: ラウンドを消費しないディスカッション用の口 ---

# 偽の companion を用意する。`task --fresh <message>` で呼ばれることと、
# 応答が標準出力へ流れることを確認する（実 Codex は呼ばない）。
fake_task_companion="$(mktemp)"
cat > "$fake_task_companion" <<'FAKE'
#!/usr/bin/env node
const argv = process.argv.slice(2);
if (argv[0] !== "task" || argv[1] !== "--fresh") {
  console.error("unexpected argv: " + JSON.stringify(argv));
  process.exit(9);
}
console.log("codex says: " + argv[2]);
FAKE

DISCUSS_FINDINGS_DIR="$(mktemp -d)"

out_discuss="$(CODEX_COMPANION="$fake_task_companion" \
  GH_FIX_ISSUE_FINDINGS_DIR="$DISCUSS_FINDINGS_DIR" \
  bash "$SCRIPTS_DIR/codex-review.sh" --discuss "この指摘は誤検知では?" 2>/dev/null)"
assert_eq "0" "$?" "--discuss は応答を得られれば 0"
assert_contains "$out_discuss" "codex says: この指摘は誤検知では?" "--discuss はメッセージを task --fresh へ渡し応答を返す"

# ラウンドを消費しない = findings-<N>.json を作らない
assert_eq "false" \
  "$([ -f "$DISCUSS_FINDINGS_DIR/findings-1.json" ] && echo true || echo false)" \
  "--discuss は findings-<N>.json を作らない（ラウンドを消費しない）"

# やりとりは discussion.md に追記される
assert_eq "true" \
  "$([ -f "$DISCUSS_FINDINGS_DIR/discussion.md" ] && echo true || echo false)" \
  "--discuss はやりとりを discussion.md に残す"

CODEX_COMPANION="$fake_task_companion" \
  GH_FIX_ISSUE_FINDINGS_DIR="$DISCUSS_FINDINGS_DIR" \
  bash "$SCRIPTS_DIR/codex-review.sh" --discuss "2回目" >/dev/null 2>&1
assert_eq "2" \
  "$(grep -c '^### Codex の回答' "$DISCUSS_FINDINGS_DIR/discussion.md")" \
  "--discuss を繰り返すと discussion.md に追記されていく"

# メッセージ未指定は usage エラー
CODEX_COMPANION="$fake_task_companion" \
  bash "$SCRIPTS_DIR/codex-review.sh" --discuss >/dev/null 2>&1
assert_eq "1" "$?" "--discuss にメッセージが無ければ usage エラーで 1"

# companion が無ければ 30（--check と同じ扱い）
CODEX_COMPANION="/nonexistent/codex-companion.mjs" \
  CODEX_REVIEW_DISABLE_GLOB=1 \
  bash "$SCRIPTS_DIR/codex-review.sh" --discuss "問い" >/dev/null 2>&1
assert_eq "30" "$?" "--discuss は companion が無ければ 30"

# companion が失敗したら 1（見解を得られていないので成功にしない）
fake_failing_companion="$(mktemp)"
printf '#!/usr/bin/env node\nprocess.exit(1);\n' > "$fake_failing_companion"
CODEX_COMPANION="$fake_failing_companion" \
  GH_FIX_ISSUE_FINDINGS_DIR="$DISCUSS_FINDINGS_DIR" \
  bash "$SCRIPTS_DIR/codex-review.sh" --discuss "問い" >/dev/null 2>&1
assert_eq "1" "$?" "--discuss は Codex の実行に失敗したら 1"

rm -f "$fake_task_companion" "$fake_failing_companion"
rm -rf "$DISCUSS_FINDINGS_DIR"

rm -rf "$GH_FIX_ISSUE_TEST_FINDINGS_DIR"
