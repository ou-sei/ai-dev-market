# 設定ローダー（gh-fix-issue-config.sh）の検証。
#
# 重点は base ブランチの解決。ここを "main" に決め打ちすると、既定ブランチが
# develop のリポジトリで「存在する別のブランチ」を base として扱ってしまい、
# 差分の基準がずれたまま lint 判定が通る。実在しないなら fetch で落ちて気づけるが、
# main が存在する develop 運用のリポジトリでは気づけない。だから決め打ちしない。

CONFIG_ORIG_PWD="$PWD"

# origin/HEAD を持つ一時リポジトリを作る。clone 経由でないと origin/HEAD は
# 付かないので、bare を作って clone する。
make_cloned_repo() {
  local default_branch="$1"
  local origin work
  origin="$(mktemp -d)"
  work="$(mktemp -d)"
  git -C "$origin" init -q --bare --initial-branch="$default_branch" .
  local seed
  seed="$(mktemp -d)"
  git -C "$seed" init -q --initial-branch="$default_branch" .
  git -C "$seed" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m seed
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -q origin "$default_branch"
  rm -rf "$work"
  work="$(mktemp -d)/clone"
  git clone -q "$origin" "$work"
  rm -rf "$seed"
  printf '%s\n' "$work"
}

# --- base ブランチを origin/HEAD から解決する ---

CLONED_DEVELOP="$(make_cloned_repo develop)"
out_resolved="$(cd "$CLONED_DEVELOP" && . "$SCRIPTS_DIR/gh-fix-issue-config.sh" \
  && load_gh_fix_issue_config >/dev/null 2>&1 && printf '%s' "$GH_FIX_ISSUE_BASE_BRANCH")"
assert_eq "develop" "$out_resolved" "既定ブランチが develop のリポジトリでは base に develop を解決する"

CLONED_MAIN="$(make_cloned_repo main)"
out_resolved_main="$(cd "$CLONED_MAIN" && . "$SCRIPTS_DIR/gh-fix-issue-config.sh" \
  && load_gh_fix_issue_config >/dev/null 2>&1 && printf '%s' "$GH_FIX_ISSUE_BASE_BRANCH")"
assert_eq "main" "$out_resolved_main" "既定ブランチが main のリポジトリでは base に main を解決する"

# --- 設定ファイルの指定が解決結果より優先される ---

mkdir -p "$CLONED_MAIN/.claude"
printf 'GH_FIX_ISSUE_BASE_BRANCH="release"\n' > "$CLONED_MAIN/.claude/gh-fix-issue.config.sh"
out_config_wins="$(cd "$CLONED_MAIN" && . "$SCRIPTS_DIR/gh-fix-issue-config.sh" \
  && load_gh_fix_issue_config >/dev/null 2>&1 && printf '%s' "$GH_FIX_ISSUE_BASE_BRANCH")"
assert_eq "release" "$out_config_wins" "設定ファイルが base を指定していればそれを使う"

# --- 解決できないときは空のままにする（main に決め打たない） ---

# remote を持たない裸のリポジトリ。origin/HEAD も無く、gh repo view も失敗する。
NO_REMOTE_REPO="$(mktemp -d)"
git -C "$NO_REMOTE_REPO" init -q .
out_unresolved="$(cd "$NO_REMOTE_REPO" && . "$SCRIPTS_DIR/gh-fix-issue-config.sh" \
  && load_gh_fix_issue_config >/dev/null 2>&1 && printf '[%s]' "$GH_FIX_ISSUE_BASE_BRANCH")"
assert_eq "[]" "$out_unresolved" "base を解決できないときは main に決め打たず空にする"

# --- 未解決の base で preflight-gates.sh を呼ぶと実行エラーで止まる ---

# 間違った基準で判定するより止める。--base も設定も無い状態。
out_no_base="$(cd "$NO_REMOTE_REPO" && bash "$SCRIPTS_DIR/preflight-gates.sh" 2>&1)"
no_base_rc=$?
assert_eq "1" "$no_base_rc" "base を解決できないなら合格にせず exit 1"
assert_contains "$out_no_base" "base ブランチを解決できませんでした" \
  "base を解決できなかったことを stderr に出す"

# --- プリセットと雛形の場所を公開する ---

out_preset_dir="$(cd "$CLONED_MAIN" && . "$SCRIPTS_DIR/gh-fix-issue-config.sh" \
  && load_gh_fix_issue_config >/dev/null 2>&1 && printf '%s' "$GH_FIX_ISSUE_PRESET_DIR")"
assert_eq "$(cd "$SCRIPTS_DIR/.." && pwd)/presets" "$out_preset_dir" \
  "GH_FIX_ISSUE_PRESET_DIR が presets/ を指す"
assert_eq "0" "$([ -f "$out_preset_dir/gh-fix-issue.config.sh.example" ] && echo 0 || echo 1)" \
  "雛形 gh-fix-issue.config.sh.example が同梱されている"
assert_eq "0" "$([ -f "$out_preset_dir/android-gradle.sh" ] && echo 0 || echo 1)" \
  "プリセット android-gradle.sh が同梱されている"

# --- 設定ファイルが無いことを警告する ---

out_warn="$(cd "$NO_REMOTE_REPO" && . "$SCRIPTS_DIR/gh-fix-issue-config.sh" \
  && load_gh_fix_issue_config >/dev/null 2>&1; warn_if_unconfigured 2>&1)"
assert_contains "$out_warn" "gh-fix-issue.config.sh がありません" \
  "設定ファイルが無いとき警告する"
assert_contains "$out_warn" "ゲートは 1 つも実行されません" \
  "未検証のまま進むことを警告に含める"

out_no_warn="$(cd "$CLONED_MAIN" && . "$SCRIPTS_DIR/gh-fix-issue-config.sh" \
  && load_gh_fix_issue_config >/dev/null 2>&1; warn_if_unconfigured 2>&1)"
assert_eq "" "$out_no_warn" "設定ファイルがあるときは警告しない"

# --- android-gradle プリセットが読み込める ---

PRESET_REPO="$(mktemp -d)"
git -C "$PRESET_REPO" init -q .
mkdir -p "$PRESET_REPO/.claude"
cat > "$PRESET_REPO/.claude/gh-fix-issue.config.sh" <<'PRESET_CONFIG'
# shellcheck disable=SC2034
. "$GH_FIX_ISSUE_PRESET_DIR/android-gradle.sh"
GH_FIX_ISSUE_BASE_BRANCH="develop"
GH_FIX_ISSUE_BUILD_DIR="gradle-root"
PRESET_CONFIG

out_preset="$(cd "$PRESET_REPO" && . "$SCRIPTS_DIR/gh-fix-issue-config.sh" \
  && load_gh_fix_issue_config >/dev/null 2>&1 \
  && printf '%s|%s|%s|%s' "$GH_FIX_ISSUE_BASE_BRANCH" "$GH_FIX_ISSUE_BUILD_DIR" \
       "$GH_FIX_ISSUE_LINT_NAME" "$GH_FIX_ISSUE_LINT_DIFF_ENABLED")"
assert_eq "develop|gradle-root|ktlintCheck|1" "$out_preset" \
  "プリセットを読んだ後の上書きが効き、プリセット由来の lint 設定も入る"

out_preset_gates="$(cd "$PRESET_REPO" && . "$SCRIPTS_DIR/gh-fix-issue-config.sh" \
  && load_gh_fix_issue_config >/dev/null 2>&1 && printf '%s' "$GH_FIX_ISSUE_GATES")"
assert_contains "$out_preset_gates" "assembleDebug" "プリセットがゲートを定義する"
assert_contains "$out_preset_gates" "PREFLIGHT_GRADLE" \
  "ゲートのコマンドに gradlew 差し替え口が残っている"

# --- bash 以外のシェルから source されても presets/ を指せる ---
#
# /gh-fix-issue のコマンド手順は、エージェントのシェル（zsh のこともある）で
# `. <loader> && load_gh_fix_issue_config` を直接実行する。zsh は BASH_SOURCE を
# 持たず、関数内の $0 は関数名になるため、関数の中で自分の位置を求めると
# リポジトリルートを指してしまう（GH_FIX_ISSUE_PRESET_DIR が壊れる）。
# テストが bash だけだとこの経路を通らないので、明示的に確かめる。
if command -v zsh >/dev/null 2>&1; then
  out_zsh_preset="$(cd "$CLONED_MAIN" && zsh -c ". \"$SCRIPTS_DIR/gh-fix-issue-config.sh\"; load_gh_fix_issue_config >/dev/null 2>&1; printf '%s' \"\$GH_FIX_ISSUE_PRESET_DIR\"")"
  assert_eq "$(cd "$SCRIPTS_DIR/.." && pwd)/presets" "$out_zsh_preset" \
    "zsh から source しても GH_FIX_ISSUE_PRESET_DIR が presets/ を指す"

  out_zsh_base="$(cd "$CLONED_DEVELOP" && zsh -c ". \"$SCRIPTS_DIR/gh-fix-issue-config.sh\"; load_gh_fix_issue_config >/dev/null 2>&1; printf '%s' \"\$GH_FIX_ISSUE_BASE_BRANCH\"")"
  assert_eq "develop" "$out_zsh_base" "zsh から source しても base ブランチを解決できる"
else
  echo "  skip zsh が無いため非 bash シェルの経路を検証していない"
fi

# --- 雛形とプリセットは bash として妥当 ---

bash -n "$out_preset_dir/gh-fix-issue.config.sh.example" 2>/dev/null
assert_eq "0" "$?" "雛形が bash として構文的に妥当"
bash -n "$out_preset_dir/android-gradle.sh" 2>/dev/null
assert_eq "0" "$?" "プリセットが bash として構文的に妥当"

cd "$CONFIG_ORIG_PWD" || exit 1
rm -rf "$CLONED_DEVELOP" "$CLONED_MAIN" "$NO_REMOTE_REPO" "$PRESET_REPO"
