# ai-dev-market の配布方式: プラグイン化

作成日: 2026-08-18

## 1. 目的

ai-dev-market に集めた command / skill を、**チームの誰でも複数のプロジェクトで使える**状態にする。

最上位の原則は次の 1 つ。

> **`gh-fix-issue` と `gh-fix-review` は、それぞれ単独でプロジェクトに導入して使える。**

片方だけ入れた人が壊れる構造を作らない。この原則が他のすべての判断に優先する。

**現時点のツールは 2 つだが、今後増える前提で設計する。** 「2 つだから手で管理できる」
に依存した仕組みを作らない。ツールが 1 つ増えるたびに人手の手順が増える構成は、
増えた分だけ登録漏れ・検証漏れの余地を作る。

## 2. 現状と課題

`claude/` 以下を `install.sh` が `~/.claude/` へファイル単位でシンボリックリンクする。
利用実績は 1 つの Android リポジトリのみ。

| 課題 | 内容 |
|---|---|
| 導入の重さ | clone してスクリプトを実行する手順が必要。チームに配るには重い |
| 発見性 | リポジトリを知らない人には存在が見えない |
| CI の取りこぼし | `claude/scripts/tests/run-tests.sh` 決め打ちで、skill のテスト 31 件が回っていない |
| ゲート定義の分散 | ゲートの実体が `gh-fix-issue` 側にあり、`gh-fix-review` から使うと単独利用の原則が崩れる |

**バージョンが無いこと自体は課題に数えない。** §6 のとおり、プラグイン化しても
利用者側でバージョンを固定する手段は無く、この点は改善しない。

## 3. 配布方式: Claude Code プラグイン

`claude plugin marketplace add` + `claude plugin install` で配る。

### private リポジトリのままで配布できる

`marketplace add` の実体は `git clone` で、その人の git 認証で読めれば private でも動く。
実測で確認した（2026-08-18）。

| 試したもの | 結果 |
|---|---|
| 存在しないリポジトリ | `Failed to clone: remote: Repository not found` |
| アクセス権の無い他人の private | `Failed to clone: remote: Repository not found` |
| **この ai-dev-market（private）** | `Marketplace file not found at .../.claude-plugin/marketplace.json` |

3 つ目は clone を突破しており、足りないのは manifest だけ。リポジトリへの
読み取り権限があればそのまま使える。**public 公開は不要。**

### メンバーの導入手順

```bash
claude plugin marketplace add ou-sei/ai-dev-market
claude plugin install gh-fix-issue@ai-dev-market        # 必要なものだけ
claude plugin install gh-fix-review@ai-dev-market
```

## 4. リポジトリ構成

`marketplace add --help` の例が `--sparse .claude-plugin plugins` を挙げているので、
これを monorepo の想定レイアウトとして採用する。

```
ai-dev-market/
├── .claude-plugin/
│   └── marketplace.json                プラグイン一覧
├── plugins/
│   ├── gh-fix-issue/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── commands/gh-fix-issue.md
│   │   └── scripts/                    codex-review / preflight-gates / ktlint-diff /
│   │                                   gh-project-status / gh-fix-issue-config / tests
│   └── gh-fix-review/
│       ├── .claude-plugin/plugin.json
│       └── skills/gh-fix-review/     SKILL.md / pr-reply.sh / threads.jq / tests
└── docs/
    ├── gh-fix-issue.md
    ├── gh-fix-review.md
    └── plugin-distribution.md          このファイル
```

**プラグインはツールごとに分ける。** 必要なものだけ入れられ、独立にバージョンを上げられる。
共有スクリプトを別プラグインに置く構成（core プラグイン）は採らない。導入手順が増え、
core のバージョンを上げるたび全プラグインの検証が必要になるため。

## 5. ゲートの契約

**プラグイン間依存を作らないため、ゲートの上書きはプラグインごとに独立させる。**

利用リポジトリは、動作を上書きしたいプラグインごとに
`.claude/<プラグイン名>.gates.sh` を置く（すべて任意）。

```
.claude/gh-fix-issue.gates.sh       gh-fix-issue の PUSH 前ゲートを上書きする
.claude/gh-fix-review.gates.sh   gh-fix-review の PUSH 前ゲートを上書きする
```

**ファイルを分けるのは、片方のプラグイン用に置いた定義がもう片方の動作を変えない
ようにするため。** 1 つの共有ファイル（`.claude/gates.sh`）に集約する案は採らない。
共有にすると「gh-fix-review 用にゲートを置いた瞬間、gh-fix-issue の config 駆動の
ゲートや lint 差分判定が止まる」という相互影響が起き、**単独利用の原則が崩れる**。
両プラグインで同じ検証をしたいリポジトリは、各ファイルから共通のスクリプトを
呼べばよい（リポジトリ側の自由であり、プラグインは関知しない）。

**命名パターン（`.claude/<プラグイン名>.gates.sh`）と終了コードの解釈は全ツール共通。**
今後追加するツールも独自の仕組みを作らずこのパターンに従う。ツールは上書きファイルを
実行し、**終了コードだけで解釈する**（標準出力の文言では判定しない）。

| exit | 意味 | 呼び出し側の扱い |
|---|---|---|
| 0 | 合格 | push へ進む |
| 10 | 不合格 | 原因を直してコミットし再実行（修正は最大 2 回・実行は最大 3 回） |
| 1 | ゲートの実行基盤自体の問題 | **直して再実行せず、停止してユーザーに提示** |
| — | 上書きファイルが存在しない | 各ツールの既定動作にフォールバックする（下記） |

exit 10 と exit 1 を混同しない。10 は「コードに直すべき原因がある」、1 は
「ゲートそのものが実行できていない」で、後者はコードを直しても解消しない。

### 現時点の 2 ツールの既定動作（上書きファイルが無い場合）

- `gh-fix-review`: 同梱の `gates.sh` がプロジェクト形式を自動検出して汎用の
  検証コマンドを実行する。検出できなければ「未検証」を明示して続行する
- `gh-fix-issue`: `preflight-gates.sh`（`.claude/gh-fix-issue.config.sh` 駆動）を実行する。
  設定が無ければゲート無しで動く（未検証であることは警告する）

**新しく追加するツールも同じパターンに従う。** フォールバックを
持たせる場合も、検証しなかったことを隠さない（黙って合格にしない）こと。

### 上書きファイルはどのプラグインにも依存させない

```bash
#!/usr/bin/env bash
# <利用リポジトリ>/.claude/gh-fix-review.gates.sh の例。
# ビルドルートが Git ルートと異なる構成では cd で移動してから実行する。
set -uo pipefail
cd "$(git rev-parse --show-toplevel)/<ビルドルート>" || exit 1
./gradlew assembleDebug        || exit 10
./gradlew testDebugUnitTest    || exit 10
```

プラグインのキャッシュを辿るラッパーにしてはいけない。片方のプラグインしか
入れていない人が壊れ、**単独利用の原則が崩れる**。

### ktlint を上書きゲートに入れない理由

実地検証したリポジトリでは ktlint が `ignoreFailures = true` に
なっており、**違反があっても `./gradlew ktlintCheck` は exit 0 を返す**。したがって
`./gradlew ktlintCheck || exit 10` と書いても**この行は絶対に発火しない**。
何もしない行を置くと「lint を見ている」という誤った印象を与えるだけなので入れない。

追加行の違反だけを見る `ktlint-diff.mjs` は `gh-fix-issue` 側の資産で、これは
`ktlintCheck` のレポート XML を読んで自前で判定するため機能する。上書きゲートから
同じことをしたい場合はそのロジックを持ち込む必要があるが、**今回は見送る**。
ktlint はもともと CI をブロックしない方針のリポジトリだったため、上書きゲートで
落とす理由が無い。

Android Lint の Fatal ゲートも上書きゲートには入れない。`preflight-gates.sh` も
実行していないため、揃えることを優先する。利用リポジトリの CI が
Fatal をブロックしており、そこで捕まる。

## 6. バージョニングの限界（重要）

`claude plugin install` に**バージョン指定の構文は無い**（`plugin@marketplace` は
マーケットプレイスの指定）。利用者は常に marketplace が指すバージョンを取る。

したがって:

- **バージョンはリリースゲートではない。** 変更履歴とキャッシュ分離のためのもの
- **`main` へのマージが実質の配布**であり、防波堤は PR レビューと CI だけ
- この点は現状の symlink 方式と実質同じで、プラグイン化しても改善しない

「バージョンがあるから安全」という前提を置かない。安全側の担保は §7 の CI に寄せる。

## 7. CI

現状の CI は `claude/scripts/tests/run-tests.sh` を決め打ちで実行しており、
skill のテスト 31 件が回っていない。プラグインが増えるたび同じ漏れが起きるため、
**発見式にする**。

| 検証 | 内容 |
|---|---|
| テスト | `find plugins -path '*/tests/run-tests.sh'` を全部実行する。決め打ちしない |
| manifest | `marketplace.json` / 各 `plugin.json` が JSON として妥当で、必須項目を持つ |
| marketplace | `claude plugin marketplace add <ローカルパス>` が通る（`install.sh` 検証の置き換え） |
| **対応** | **`plugins/` の各ディレクトリが `marketplace.json` に登録されているか。逆に `marketplace.json` の各エントリに対応するディレクトリがあるか（双方向）** |
| version | `plugins/<名前>/` に変更があるのに `plugin.json` の `version` が据え置きなら落とす |
| 構文 | 既存どおり `bash -n` を全 `.sh` に |

`version` 据え置きの検出を入れるのは、§6 のとおり配布が `main` マージで起きるため。
バージョンが動かないと利用者側のキャッシュが更新されない可能性がある。

**対応の双方向検証はツールが増えるほど重要になる。** ディレクトリを足したのに
`marketplace.json` へ登録し忘れると、そのツールは**誰にも配布されないまま緑で通る**。
逆にエントリだけ残ると `plugin install` が失敗する。どちらも人手では気づきにくい。

## 8. 新しいツールを追加する手順

ツールは増える前提なので、毎回同じ形になるよう手順を固定する。

1. `plugins/<ツール名>/` を作る
2. `.claude-plugin/plugin.json` を置く（`name` / `description` / `version` / `repository`）
3. 中身を種類ごとの標準の場所に置く
   - スラッシュコマンドのみで完結し、明示的に打って起動したいもの → `commands/<名前>.md`
   - スクリプトやテストを伴うもの、文脈から自動選択されたいもの → `skills/<名前>/SKILL.md`
   - そのツール専用のスクリプト → `plugins/<ツール名>/scripts/`
4. テストは `plugins/<ツール名>/**/tests/run-tests.sh` に置く。CI が発見して実行する
5. **`.claude-plugin/marketplace.json` にエントリを追加する**（CI が対応を検証する）
6. `docs/<ツール名>.md` に設計と運用を書く
7. README のツール表に 1 行足す
8. push 前の検証が必要なら `.claude/<プラグイン名>.gates.sh` 契約（§5）に従う。独自の仕組みを作らない

### command と skill の使い分け

| | `commands/` | `skills/` |
|---|---|---|
| 単位 | 単一 `.md` | ディレクトリ（付随ファイルを同梱できる） |
| 引数 | `$ARGUMENTS` を本文に展開できる | 展開記法は無い（呼び出し時に渡る） |
| ツール制限 | `allowed-tools` で絞れる | 指定なし |
| 起動 | `/名前` を打つ必要がある | `/名前` でも、`description` からモデルが自動選択でも |

**スクリプトやテストを伴うなら skill を選ぶ。** command は単一ファイルなので、
スクリプトを別の場所に置くことになり、どのツールの資産か分からなくなる。

### ツールが増えたときの導入手順

`claude plugin install` はプラグインを 1 つずつ指定する。ツールが増えると
利用者は必要な数だけコマンドを打つことになる。**まとめて入れる仕組みは無い**
（プラグインが他のプラグインへの依存を宣言する仕組みが無いため、メタプラグインも作れない）。

README には「よく使う組み合わせ」を並べて、コピーで済むようにする。

## 9. `install.sh` は廃止する

`marketplace add` は**パスも受け付ける**ので、ai-dev-market 自身の開発時は次で足りる。

```bash
claude plugin marketplace add /path/to/ai-dev-market
```

symlink 方式を並走させる理由がなくなる。並走させると「リンクとプラグインの
どちらが効いているか分からない」状態を生む。

## 10. 移行手順

移行元のリポジトリは symlink 方式で動いていたため、順序を守らないと
リンクとプラグインが二重に見える。

1. `plugins/` へ再配置し `.claude-plugin/marketplace.json` と各 `plugin.json` を追加
2. `install.sh` と `claude/` を削除
3. CI を §7 の内容に差し替える
4. ローカルパスで `marketplace add` して自分で検証する
5. **`~/.claude/{commands,scripts,skills}` の symlink を撤去する**
6. 利用リポジトリにゲートの上書きファイル（§5）を追加する
7. README にメンバー向けの導入手順を書く

**5 を飛ばすと古いリンクが残り、プラグイン版と混在する。** `install.sh` を消した後は
リンクを張り直す手段が無くなるので、撤去前にプラグイン版が動くことを確認する（4 → 5 の順）。

### PR #1 の扱い

PR #1（`/gh-fix-review` の追加）は `claude/skills/gh-fix-review/` にファイルを置いており、
この移行で `plugins/gh-fix-review/skills/` へ動く。**先に PR #1 をマージし、移行 PR で
移動させる。** 逆順にすると PR #1 が移行後の構成と衝突し、レビュー済みの内容を
作り直すことになる。

## 11. スコープ外

- **`/gh-fix-issue` を command から skill へ寄せること。** `$ARGUMENTS` と `allowed-tools` を
  使っており書き換えが必要で、単独利用という今回の目的には寄与しない。command のまま配る
- **利用者側でのバージョン固定。** §6 のとおり CLI が対応していない
- **`.claude/gh-fix-issue.config.sh` の廃止。** `gh-fix-issue` のフォールバック経路で
  引き続き使う。`.claude/gh-fix-issue.gates.sh` があるリポジトリではゲート定義として読まれないだけ
