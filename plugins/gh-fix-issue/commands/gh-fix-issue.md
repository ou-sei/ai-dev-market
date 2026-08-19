---
description: GitHub Issue を取得し、実装からセルフレビュー・Codex レビュー・PR 作成まで通す
argument-hint: '<issue番号>'
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, TodoWrite, AskUserQuestion
---

Issue 番号 `$ARGUMENTS` を起点に、PR 作成まで一気通貫で実行する。

## このコマンド内でのスキル規則の上書き

`codex:codex-result-handling` スキルには「レビュー指摘の自動修正は禁止。修正前に必ずユーザーに確認する」という規則がある。
**このコマンドの実行中に限り、この規則を上書きする。** ステップ 5 のループでは、対応必須の指摘を確認なしで修正する。
上書きの範囲はこのコマンド内に限る。`/codex:review` や `/codex:adversarial-review` を単体で使う場合は従来どおり従うこと。

## 中断条件

以下に該当したら、そこで止めて理由と現在の状態を提示し、ユーザーに確認する。PR は作らない。

- 未コミットの変更がある（ステップ 2 の前）
- Issue が曖昧で実装方針が一意に決まらない
- CLAUDE.md §8「触らないもの」を変更する必要が出た
- ゲート実行が 3 回目（修正 2 回まで）も exit 10 で失敗する、またはゲートスクリプトの実行自体が失敗した（終了コード 1）
- 4 周目終了時に対応必須の指摘が残っている
- Codex の指摘についてディスカッションを 3 往復しても決着しない
- Codex が使えない

逆に、以下は**停止しない**。実装・レビュー・PR という本体の成果を、メタデータ操作の
失敗で捨てるべきではないため。スキップした事実はステップ 9 でまとめて報告する。

- `project` スコープが無く Projects を更新できない
- Projects の Status 更新に失敗した
- Issue の Assignees 設定に失敗した
- Issue に Milestone が無く PR に引き継げない
- Issue 本文の更新に失敗した（タスクリストのチェック / `### 関連PR` の追加）
- PR へのコメント投稿に失敗した

## 手順

### 0. 設定の読み込みと疎通確認

このコマンドは ai-dev-market プラグインとして配布され、**すべてのリポジトリで共有される**。base ブランチ・
ブランチ命名・ビルドコマンド・Projects 名・レビュー基準といったリポジトリ固有の値は
コマンド側に持たず、各リポジトリの設定ファイルから読む。

まず設定を読み込み、以降の手順で使う値を確定させる。

```bash
. ${CLAUDE_PLUGIN_ROOT}/scripts/gh-fix-issue-config.sh && load_gh_fix_issue_config && {
  BRANCH="${GH_FIX_ISSUE_BRANCH_TEMPLATE/\{issue\}/$ARGUMENTS}"
  echo "config     : ${GH_FIX_ISSUE_CONFIG_LOADED:-（なし＝既定値で動作）}"
  echo "base       : $GH_FIX_ISSUE_BASE_BRANCH"
  echo "branch     : $BRANCH"
  echo "build dir  : $GH_FIX_ISSUE_BUILD_DIR"
  echo "projects   : ${GH_FIX_ISSUE_ISSUE_PROJECT:-（未設定＝Projects 更新なし）} / ${GH_FIX_ISSUE_PR_PROJECT:-未設定}"
}
```

**この出力をユーザーに提示する。** どの設定で動くのかを、実装を始める前に見せるため。

`config` が「なし」の場合、そのリポジトリには設定ファイルが無い。既定値
（base=`main`、ゲート無し、Projects 更新なし）で動くので、**ビルドもテストも走らない**。
それでよいか判断できないときは、ここで停止して確認する。設定ファイルの雛形は
`${CLAUDE_PLUGIN_ROOT}/scripts/gh-fix-issue-config.sh` の冒頭コメントにある。

以降の手順に出てくる `$GH_FIX_ISSUE_*` と `$BRANCH` は、ここで読み込んだ値を指す。
**同じシェル呼び出しの中で使うか、都度読み直すこと**（Bash ツールの呼び出しをまたぐと
変数は失われる）。

### 0.1 Codex の疎通確認

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --check
```

終了コードで分岐する。

| code | 動作 |
|---|---|
| 0 | 次のステップへ進む |
| 30 | `/codex:setup` を案内して停止する |

あわせて Projects の権限も確認する。

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/gh-project-status.sh --check
```

終了コード 30（`project` スコープ無し）でも**フローは停止しない**。Projects の更新は
メタデータ操作であり、実装・レビュー・PR 作成という本体の価値を止める理由にならないため。
その場合は以降の Projects 関連ステップをすべてスキップし、最後にまとめて
「`gh auth refresh -h github.com -s project` を実行すれば Projects も自動更新できる」旨を報告する。

### 1. Issue 取得

```bash
gh issue view $ARGUMENTS --json number,title,body,labels,comments,milestone
```

内容を読み、何を作るのかを 2-3 行で要約して提示する。
仕様が書かれておらず実装方針が一意に決まらない場合は、ここで停止して質問する。

Milestone はステップ 7 で PR に引き継ぐので、この時点の値を覚えておく。

### 2. 作業ブランチ

```bash
git status --short --untracked-files=all
```

出力があれば停止する。**この場合の選択肢は「退避してユーザーに確認する」の一択のみで、
「無視して進める」は選ばない。** 特に `.env*` / `*key*` / `*.pem` / `*.p12` / `*.jks` /
`*.keystore` に該当するファイル（追跡・未追跡どちらも）が見えている場合は、無関係な
機密情報をこの後のコミット・push に巻き込む恐れがあるため、ユーザーの明示的な指示なしに
一切進めない。

出力が空なら、取得と分岐作成を1つずつ実行し、途中で失敗したらチェーンを継続せず都度判断する。

**ベースはローカルの `develop` ではなく `origin/develop` を直接使う。**
ローカル `develop` を経由すると、そこに独自コミットがあった場合に `git pull` が
マージコミットを作り、**意図しない土台の上に実装が乗る**（しかも pull は成功するので
停止条件に引っかからない）。ブランチを切りたいだけなのにローカル `develop` を
書き換えてしまう副作用もある。

```bash
git fetch origin "$GH_FIX_ISSUE_BASE_BRANCH"
```

失敗したら（ネットワーク・認証エラー等）停止し、理由と現在の状態をユーザーに提示する。

```bash
git checkout -b "$BRANCH" "origin/$GH_FIX_ISSUE_BASE_BRANCH"
```

失敗したら（同じ Issue の再実行で同名ブランチが既に存在する場合など）、自動では進めず、
次のどちらにするかをユーザーに確認する。

- 既存の `feature/ousei/fix_$ARGUMENTS` を使い続ける（`git checkout feature/ousei/fix_$ARGUMENTS`）
- 別名のブランチを作る

いずれの場合も、実装（ステップ 3）に入る前に次を実行し、意図したブランチに乗っていることを
確認する。develop 上で実装・コミットが進んでしまうのが最も回復コストの高い失敗のため、
ここは省略しない。

```bash
git rev-parse --abbrev-ref HEAD
```

出力が `feature/ousei/fix_$ARGUMENTS`（またはユーザーが選んだ既存ブランチ名）と一致しなければ、
そこで停止する。

### 2.5 Issue の着手状態を反映

**ブランチ作成まで通ってから**実行する。ステップ 2 は未コミット変更があれば必ず停止するため、
これより前に置くと「1 行も実装していないのに Issue が自分に割り当たり In progress のまま残る」
状態を作りうる。作業ツリーが汚れているのは日常的に起きるので、この順序は守ること。

```bash
gh issue edit $ARGUMENTS --add-assignee @me
bash ${CLAUDE_PLUGIN_ROOT}/scripts/gh-project-status.sh --issue $ARGUMENTS \
  --project "$GH_FIX_ISSUE_ISSUE_PROJECT" --status "$GH_FIX_ISSUE_STATUS_START"
```

`@me` は実行中の gh アカウントに解決される。特定の個人名をハードコードしない
（このコマンドはチームで共有されるため、実行した人に割り当たるのが正しい）。

Mobile Issues 側は変更しない。Android 側だけを更新する。

いずれかが失敗しても**停止しない**。理由を控えておき、最後にまとめて報告する。

### 3. 実装

CLAUDE.md の実装規約に従う。特に:

- 新規 ViewModel は `@HiltViewModel` + `hiltViewModel()`
- 新規 Compose 画面は Material 3
- Apollo は suspend 版（`requestApollo`）。`commonApolloRequest` は使わない
- Apollo 生成型は nullable が既定。`!!` を使わない

CLAUDE.md §8「触らないもの」に触れる必要が出たら停止して確認する。

### 4. セルフレビュー

`REVIEW.md` と CLAUDE.md §7「コミット前に確認すること」の項目で自分の差分を点検し、
見つけた問題を修正する。点検した項目と結果を箇条書きで提示する。

修正後にコミットする。**`git add -A` は使わない。** 作業ツリー全体を無条件でステージすると、
このリポジトリに既にある無関係な untracked/staged ファイル（例: SSH 秘密鍵、`.env.local`
のような設定ファイル）を無人で巻き込み、そのままコミット・push・PR 作成まで進んでしまう。

このステップで実装のために作成・変更したパスだけを明示的に指定してステージする
（例: `git add app/src/main/kotlin/... app/src/main/res/...`）。

ステージした直後、コミットする前に必ず次を実行する。

```bash
git status --short --untracked-files=all
```

Issue の実装と無関係なファイルが1件でも見えている場合、`.env*` / `*key*` / `*.pem` /
`*.p12` / `*.jks` / `*.keystore` に該当するかを確認する。該当する、またはそれが何か
判断できない場合はステージせず停止し、ユーザーに確認する。**「無視して進める」という
選択肢は無い。**

```bash
git commit -m "<Issue タイトル> #$ARGUMENTS"
```

`pre-commit-review.sh` hook が 1 回ブロックする。上記のセルフレビューを実施済みなので、
同じコマンドをもう一度実行して通す。

### 5. Codex レビューループ

`round` を 1 から始め、以下を繰り返す。**最低 1 周は必ず実行する**（ステップ 4 のセルフレビューで
何も見つからなかった場合でも、このループ自体は省略しない）。

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --round <round> --base "$GH_FIX_ISSUE_BASE_BRANCH" > /tmp/codex-round.log 2>&1; echo "EXIT=$?"
cat /tmp/codex-round.log
```

**出力をパイプ（`| tail` 等）に通さないこと。** 終了コードを取り損ねる。
Codex レビューは実行に数分かかるうえ、`--round 1` は findings ディレクトリを作り直すため、
取り直すには**同じレビューをもう一度回すことになる**（1 回目の結果は失われる）。
上記のようにファイルへリダイレクトし、直後に `$?` を取ってから内容を読むこと。

終了コードで分岐する。

| code | 動作 |
|---|---|
| 0 | 対応必須の指摘なし。**ただし「任意」の指摘があれば下記「指摘の扱い」で処理してから**ステップ 6 へ |
| 10 | 対応必須の指摘あり。**下記「指摘の扱い」に従って 1 件ずつ妥当性を確認**し、修正したものがあればコミットして `round + 1` で再実行 |
| 20 | ラウンド上限（4 周）超過。残っている指摘を提示して停止 |
| 30 | Codex が使えない。`/codex:setup` を案内して停止 |
| 1 | 実行エラー。標準エラー出力を提示して停止 |

#### 指摘の扱い（severity を問わず、まず妥当性を確認する）

**「対応必須」と表示されたかどうかに関係なく、Codex の指摘は 1 件ずつ妥当性を確認してから
扱いを決める。** 表示ラベルは severity の機械的な写像でしかなく、正しさの保証ではない。
検証せずに直すのも、検証せずに無視するのも等しく誤り。

実績として、静的解析由来の指摘は誤検知が珍しくない（Android Lint の Fatal 5 件のうち
真の不具合は 1 件、detekt の `UnreachableCode` 15 件は全件が誤検知だった）。

各指摘を次の 3 つに分類する。

| 分類 | 条件 | 対応 |
|---|---|---|
| **(a) 妥当** | 指摘のとおり問題がある | **severity を問わず修正する。** medium / low でも直す |
| **(b) 誤り** | 誤検知、前提の取り違え、既に対応済み | **Codex とディスカッションする**（後述）。修正しない |
| **(c) 妥当だがスコープ外** | 指摘は正しいが、この Issue の範囲を超える | 修正しない。**理由を PR 本文に書く。**必要なら別 Issue を立てる |

(c) は「Issue 本文が明示的に別対応としている」場合に限る。面倒だから、では使わない。
判断がつかないときは (a) として扱う。

#### 誤りだと考えたときのディスカッション

**独断で無視しない。** Codex に反論して見解を求める。

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/codex-review.sh --discuss "<反論>" > /tmp/codex-discuss.log 2>&1; echo "EXIT=$?"
cat /tmp/codex-discuss.log
```

**`--discuss` はレビューのラウンドを消費しない。** `--round` を取らず
`findings-<N>.json` も書き換えないので、何回使ってもループ回数は増えない。
納得できるまで往復してよい。

反論には次を必ず含める。レビュー本体とは別スレッドになるため、Codex は前の文脈を
持っていない。

- 指摘の全文（`findings-<round>.json` からそのまま引く）
- 該当コード（`file:line` と実際の行）
- こちらの反論と、その根拠（コンパイルが通っている、既に別の箇所で対処済み、など）
- 求める回答の形（例:「指摘が妥当 / 反論が妥当 のどちらかと理由を3行以内で」）

終了コードで分岐する。

| code | 動作 |
|---|---|
| 0 | 見解を取得した。内容を読んで判断する |
| 30 | Codex が使えない。`/codex:setup` を案内して停止 |
| 1 | 実行エラー。標準エラー出力を提示して停止 |

`--discuss` は 10 を返さない。**採否の判断は Claude 側の仕事**で、このコマンドは
見解を取れたかどうかだけを返す。

やりとりの結果で次のように進める。

- **Codex が反論を認めた** → 修正しない。判断の根拠として PR 本文に 1 行残す
- **Codex が指摘を維持し、こちらが納得した** → (a) として修正する
- **3 往復しても決着しない** → **停止してユーザーに確認する。**押し切らない

やりとりは `<repo-root>/.git/gh-fix-issue/discussion.md` に追記される。
ステップ 7 で PR 本文に根拠を書くときに参照する。

#### 修正のコミット

**ここでも `git add -A` は使わない。** この周で指摘に対応するために変更したパスだけを
明示的に指定してステージし、ステップ 4 と同じ確認
（`git status --short --untracked-files=all` で無関係なファイル・secret 形状のファイルが
無いことを確認する。無視して進める選択肢は無い）を実施したうえでコミットする。

```bash
git add <この周で変更したパス> && git commit -m "Codex レビュー指摘対応 (round <round>)"
```

`pre-commit-review.sh` hook は staged 差分のハッシュ単位でブロックするため、この修正コミットも
毎回（ステップ 4 の初回コミットだけでなく、ラウンドごとに）1 回ブロックされる。
同じコマンドをもう一度実行して通す。

修正が 1 件でもあれば、コミットして `round + 1` で再実行する。
**(b)(c) しか無く修正が 1 件も無い場合は、次のラウンドを回さずステップ 6 へ進む。**
同じ指摘がもう一度返ってくるだけで、ラウンドを浪費するため。

各ラウンドの指摘全文は `<repo-root>/.git/gh-fix-issue/findings-<round>.json` に保存される。
ステップ 7 の PR 本文作成時に参照する。

### 6. PUSH 前ゲート

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight-gates.sh" \
  --base "$GH_FIX_ISSUE_BASE_BRANCH" > /tmp/preflight.log 2>&1; echo "EXIT=$?"
cat /tmp/preflight.log
```

**出力をパイプ（`| tail` 等）に通さないこと。** 終了コードを取り損ね、ビルドとテストを
まるごとやり直すことになる。ファイルへリダイレクトし、直後に `$?` を取ってから内容を読む。

リポジトリに `<repo-root>/.claude/gh-fix-issue.gates.sh`（このコマンド専用の上書きゲート）が
ある場合、`preflight-gates.sh` はそれに委譲する。終了コードの契約（0 / 10 / 1）は同じなので、
以降の分岐は変わらない。

終了コードで分岐する。**必ず終了コードで判定し、出力の文言では判定しない。**

| code | 動作 |
|---|---|
| 0 | 全ゲート合格。ステップ 7 へ進む |
| 10 | 標準エラー出力の `不合格のゲート:` に列挙された原因を直してコミットし、再実行する（回数の数え方は下記） |
| 1 | ゲートの実行基盤に問題があり、結果全体が信用できない状態（例: ktlint レポートに XML が無い、`--repo-root` の不整合など）。**これは「直して再実行」の対象ではない。** 先行するビルド／テストのゲートが既に失敗していて、その `FAILED` 表示（標準出力側に出る）がこの実行エラーに埋もれている可能性がある。標準エラー出力の診断内容だけでなく、それまでの標準出力のゲート出力（`== <ゲート名>` / `OK` / `FAILED` の並び）も併せて提示して停止する |

`不合格のゲート:` は常に標準エラー出力に出る。終了コード 10 のときはこの行が出て、終了コード 1 のときは出ない
（ktlint-diff の実行エラーで `exit 1` するのが `不合格のゲート:` を出す前段なため）。ただしこれは説明であって
判定基準ではない。**分岐は終了コードそのもので行い、この行の有無や標準出力／標準エラー出力の文言では判定しない。**

**ゲート実行とやり直しの回数（修正は最大 2 回、ゲート実行は最大 3 回まで）:**

1. 1 回目のゲート実行が exit 10 で失敗 → 原因を直してコミットする（修正 1 回目）。2 回目のゲート実行に進む
2. 2 回目のゲート実行も exit 10 で失敗 → 原因を直してコミットする（修正 2 回目）。3 回目のゲート実行に進む
3. 3 回目のゲート実行も exit 10 で失敗 → それ以上は修正せず、理由と現在の状態を提示して停止する

exit 1 が出た場合は、この回数のどの段階であっても直ちに停止する（上記の表のとおり、修正・再実行の対象ではない）。

`PREFLIGHT_SKIP_KTLINT` や（ステップ 5 の）`CODEX_REVIEW_FIXTURE` のようなテスト用の
バイパス環境変数が立っていると、標準エラー出力に「警告: ... スキップしました」
「警告: CODEX_REVIEW_FIXTURE が設定されているため...」が出る。このコマンドの通常実行では
これらの env は立てない前提だが、もし出力中にこれらの警告が見えたら、そのゲート/ラウンドは
実際には検証・レビューされていない。ステップ 7 の PR 本文にその旨を必ず明記する
（「OK」と書かない）。

### 6.5 Issue の進捗を反映

Issue 本文にタスクリスト（`- [ ]`）がある場合、**この対応で実際に実装したものだけ**にチェックを付ける。

**必ず本文を取り直してから編集する。** ステップ 1 の取得からここまでに実装・最大 4 周の
Codex レビュー・Gradle ビルドが挟まり、実時間で数十分経っている。その間に人間が Issue 本文を
編集していた場合、古い本文で上書きするとその編集が無言で消える。

```bash
gh issue view $ARGUMENTS --json body -q .body > .git/gh-fix-issue/issue-body.md
cp .git/gh-fix-issue/issue-body.md .git/gh-fix-issue/issue-body.orig.md
```

`.git/gh-fix-issue/issue-body.md` を編集する。**変更してよいのはチェックボックスの
`- [ ]` を `- [x]` にすることだけ。** 文言・順序・空行・その他の行は一切変更しない。
整形も要約も言い換えもしない。

編集後、変更がチェックボックスだけに収まっているか確認する。

```bash
diff .git/gh-fix-issue/issue-body.orig.md .git/gh-fix-issue/issue-body.md
```

差分に `- [ ]` → `- [x]` 以外の変更が含まれていたら、**適用せず**にやり直す。
確認できたら反映する（`--body-file` はパスを取る。本文そのものを渡すのではない）。

```bash
gh issue edit $ARGUMENTS --body-file .git/gh-fix-issue/issue-body.md
```

判断基準は「実装したか」であって「完了しそうか」ではない。
**このフローの中で検証まで済んでいない項目にはチェックを付けない。**
たとえば「CI で JDK 18 が引き続き解決されることを確認する」のような項目は、
PR がマージされて CI が走るまで確認できないので未チェックのまま残す。

チェックを付けなかった項目がある場合、その理由（何が未検証か）を控えておき、
ステップ 7 の PR 本文に記載する。Issue を見た人が「チェックが無い＝手つかず」と
誤解しないようにするため。

タスクリストが無い Issue では何もしない。

このステップが失敗しても**停止しない**。ここは push と PR 作成の直前であり、
ゲートまで通した成果を本文更新の失敗で捨てるべきではない。控えてステップ 9 で報告する。

### 7. PUSH と PR 作成

```bash
git push -u origin "$BRANCH"
```

PR 本文を組み立てる。各周のレビュー結果は `.git/gh-fix-issue/findings-<N>.json` にある。
ゲートの行はステップ 6 の実際の出力から埋める。ハードコードした `OK` をそのまま使わない
（ステップ 6 の警告が出ていた場合はここに「スキップ」「fixture 使用」等を明記する）。

本文はリポジトリの `.github/PULL_REQUEST_TEMPLATE.md` の見出し構成に合わせる。

**`Closes` / `Fixes` などの closing keyword は使わない。** このリポジトリは
マージ後に QA 工程（Android Issues の `🔍 Ready for QA` / `🕵🏻 In QA`）があり、
マージ時点で Issue が自動クローズされると QA 前に閉じてしまう。
既存 PR（#3454 / #3445 / #3441）もすべて `### 関連Issue` への言及のみで統一されている。

Milestone は**ステップ 1 で取得した Issue の値**を引き継ぐ。

**本文は `--body-file` でファイルから渡す。** heredoc をシェルに直接埋め込むと 2 つの事故が起きる。

1. `<<'BODY'`（クォート済み）は変数を展開しないため、`$ARGUMENTS` が literal のまま PR 本文に入る
2. クォートを外すと今度は本文中の `` ` `` やコマンド置換がシェルに解釈され、意図しない実行や欠落が起きる

そこで、**プレースホルダーを実値で埋めた完成形のファイルを書いてから渡す**。
`<Issue タイトル>` `<N>` `<変更点>` のような山括弧のプレースホルダーが 1 つでも
残っていないか、作成前に必ず確認すること。

```bash
# 下記テンプレートの山括弧部分をすべて実値に置き換えたものを書き出す
#   .git/gh-fix-issue/pr-body.md
grep -n '<[^>]*>' .git/gh-fix-issue/pr-body.md   # 何も出なければ埋め残しなし
```

````markdown
### 関連Issue
- #$ARGUMENTS

### 概要

<何を解決したか。1-3行>

### 変更点（必要ならスクリーンショット貼る）

- <変更点>

### 影響範囲（修正箇所が呼び出しされている箇所を記載）

<変更が呼び出されている箇所。無ければその旨>

### セルフテスト項目
- [x] assembleQaDebug: <ステップ6の実際の出力に基づく結果>
- [x] testqaReleaseUnitTest: <同上>
- [x] ktlint（追加行）: <同上。PREFLIGHT_SKIP_KTLINT でスキップした場合は「スキップ（未検証）」と明記する>

### レビュアーへのコメント（特にレビューしてほしい観点や迷ったところなど）
- Codex レビュー: <N> 周実行。対応した指摘（critical / high）: <件数>
  - <severity> <title> — <どう直したか>
- 修正しなかった指摘: <無ければ「なし」。あれば 1 件ずつ、分類と理由を書く>
  - `[誤り]` <指摘の要約> — <なぜ誤りか。Codex とのディスカッション結果があれば併記>
  - `[スコープ外]` <指摘の要約> — <Issue のどの記述により範囲外か。別 Issue を立てたなら番号>
- Issue の未チェック項目: <ステップ 6.5 でチェックしなかった項目と、その理由。無ければ「なし」>

### 関連URL（関連Issue以外の関連するAPIのPRなど）
- <無ければ「なし」>
````

埋め残しが無いことを確認したら、ファイルを渡して作成する。

```bash
gh pr create --base "$GH_FIX_ISSUE_BASE_BRANCH" \
  --title "<Issue タイトル> #$ARGUMENTS" \
  --milestone "<Issue の milestone。無ければこのオプションごと省略する>" \
  --body-file .git/gh-fix-issue/pr-body.md
```

`--title` の `$ARGUMENTS` はシェルが展開する（クォート済み heredoc の中ではないため）。
タイトルにも山括弧のプレースホルダーが残っていないか確認すること。

Issue に Milestone が無かった場合は `--milestone` を付けずに作成し、
その事実を控えておいて最後に報告する。ここで勝手に別の Milestone を推測して付けない。

### 8. Issue と PR の状態を更新

PR 作成後に以下を行う。**いずれが失敗してもフローは停止しない**（PR は既に存在しており、
メタデータの更新失敗を理由に成果を捨てるべきではない）。失敗したものは控えて最後に報告する。

まず PR 番号を取得する。`gh pr create` が出力するのは URL であって番号ではない。
Issue と PR は同じ採番列を共有するため（#3462 が Issue、#3463 が PR）、
番号を取り違えると**別の実在する PR の Status を書き換える**。手で書かず必ず取得する。

```bash
PR_NUMBER="$(gh pr view --json number -q .number)"
```

Issue 本文の**先頭**に `### 関連PR` を追加して PR を紐付ける。
コメントではなく本文に書くのは、Issue を開いた人がスクロールせずに対応 PR へ辿れるようにするため。

ステップ 6.5 と同じ手順を踏む。**必ず本文を取り直してから編集する**（ステップ 6.5 で
本文を更新しているので、そのときのファイルを使い回さない）。

```bash
gh issue view $ARGUMENTS --json body -q .body > .git/gh-fix-issue/issue-body.md
cp .git/gh-fix-issue/issue-body.md .git/gh-fix-issue/issue-body.orig.md
```

`.git/gh-fix-issue/issue-body.md` を編集する。既存の内容は一切変更せず、**先頭への追加だけ**を行う。

- `### 関連PR` が**まだ無い場合** — 本文の一番上に次を挿入し、既存の本文との間に空行を1行入れる

  ```markdown
  ### 関連PR
  - #<PR番号>
  ```

- `### 関連PR` が**既にある場合**（同じ Issue で 2 本目の PR を作ったとき）— 見出しを重複させず、
  そのリストの末尾に `- #<PR番号>` を追加する。**同じ PR 番号が既にあれば何もしない**（再実行しても増えない）

編集後、変更が意図した範囲に収まっているか確認する。

```bash
diff .git/gh-fix-issue/issue-body.orig.md .git/gh-fix-issue/issue-body.md
```

差分が「`### 関連PR` の追加」または「既存リストへの1行追加」以外を含んでいたら、**適用せず**にやり直す。
確認できたら反映する。

```bash
gh issue edit $ARGUMENTS --body-file .git/gh-fix-issue/issue-body.md
```

`gh issue comment` による通知は行わない。本文の `### 関連PR` に一本化する。

Issue と PR の Status を進める。

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/gh-project-status.sh --issue $ARGUMENTS \
  --project "$GH_FIX_ISSUE_ISSUE_PROJECT" --status "$GH_FIX_ISSUE_STATUS_REVIEWED"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/gh-project-status.sh --pr "$PR_NUMBER" \
  --project "$GH_FIX_ISSUE_PR_PROJECT" --status "$GH_FIX_ISSUE_STATUS_PR"
```

PR 側は `add_pull_requests_to_projects.yml` による**自動追加が非同期**で、作成直後だと
まだ Project に登録されていないことがある。その場合スクリプトは
「対象はどの Project にも登録されていません」で終了コード 1 を返す。
このときは 5 秒待って再実行し、最大 3 回まで試す。3 回とも失敗したら諦めて報告に回す。
自動追加の遅れは失敗ではないので、これを理由に停止しない。

**修正しなかった指摘が 1 件も無い場合に限り**、PR に Codex の結果を添えたコメントを残す。
（severity ではなく「対応したかどうか」で判断する。medium / low でも妥当なら修正するため）
単なる LGTM ではなく、何周回して何を見たのかを書く。レビュアーがそれを判断材料にできるようにするため。

**本文は最終状態と履歴の両方が読めるように書く。** ループ中に critical / high を検出して
修正した場合でも最終的な未対応は 0 件になりうるが、そこで「指摘はありませんでした」と書くと、
同じ PR の本文にある「対応した指摘: N 件」と矛盾し、レビュアーに「レビューで何も出なかった」
という誤った印象を与える。検出件数と対応済みであることを明示する。

PR 本文と同じく、山括弧を実値で埋めたファイルを書いてから渡す。

````markdown
Codex レビューを <N> 周実行しました。

- 対応必須（critical / high）: <検出 M 件、すべて修正済み。0 件なら「検出なし」>
- 修正しなかった指摘: なし
- 対象: <base> との差分
- レビュー基準: CLAUDE.md / REVIEW.md
- 最終 verdict: <approve / needs-attention>
- <Codex の summary をそのまま引用>
````

```bash
grep -n '<[^>]*>' .git/gh-fix-issue/pr-comment.md   # 何も出なければ埋め残しなし
gh pr comment "$PR_NUMBER" --body-file .git/gh-fix-issue/pr-comment.md
```

最終ラウンドの verdict が `approve` のときだけ、末尾に `LGTM` を添えてよい。
`needs-attention` のまま LGTM と書かない。

修正しなかった指摘がある場合はこのコメント自体を出さない。指摘を残したまま LGTM と書くと誤解を招くため。

ディスカッションで Codex が反論を認めた指摘があれば、コメント本文に 1 行足す。
「レビューで何も出なかった」との区別がつくようにするため。

```
- ディスカッションの結果、取り下げられた指摘: <N> 件（詳細は PR 本文）
```

### 9. 報告

PR の URL を提示する。あわせて、途中でスキップ・失敗したものが**ひとつ残らず**列挙する。
下記は代表例であって網羅リストではない。ここに書かれていない失敗も必ず報告する。

- `project` スコープが無く Projects を更新できなかった
- Projects の Status 更新に失敗した（Issue 側 / PR 側それぞれ）
- Issue の Assignees 設定に失敗した
- Issue に Milestone が無く PR に設定できなかった
- Issue 本文の更新に失敗した（タスクリストのチェック / `### 関連PR` の追加）
- Issue のタスクリストで未チェックのまま残した項目とその理由
- PR へのコメント投稿に失敗した

黙って飛ばさない。ユーザーが後から手で直せるように、何がされなかったかを明示する。

## シェルを書くときの注意

このコマンドの手順では日本語混じりの `bash` を組み立てる場面が多い。
**シェル変数は必ず `${}` で囲むこと。** 全角文字が変数名の直後に来ると変数名の一部として
解釈され、`set -u` と組み合わさって `unbound variable` で落ちる。

```bash
echo "$status」に設定"    # 壊れる
echo "${status}」に設定"  # 正しい
```

## スクリプトの終了コードを取るときの注意

このフローの判定はすべて終了コードで行う。**スクリプトの出力をパイプに通すと終了コードを
取り損ねる。** ファイルへリダイレクトし、直後に `$?` を取ってから内容を読むこと。

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/<script>.sh <args> > /tmp/out.log 2>&1; echo "EXIT=$?"
cat /tmp/out.log
```

`| tail -20` のように出力を絞りたくなるが、それをやると終了コードが失われる。
Codex レビューもゲートも実行に数分かかるため、取り直しの代償が大きい。
特に `codex-review.sh --round 1` は findings ディレクトリを作り直すので、
再実行すると**前回の結果が失われる**（PR 本文に引用した内容と、保存されている
findings が食い違う原因になる）。
