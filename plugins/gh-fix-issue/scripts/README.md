# `scripts/`

`/gh-fix-issue` フローが使うスクリプト群。
いずれも単体で実行でき、結果は**終了コード**で返す。標準出力の文言では判定しない。

設計と運用は ai-dev-market の `docs/gh-fix-issue.md`。

## 一覧

| スクリプト | 役割 | `/gh-fix-issue` 専用か |
|---|---|---|
| `codex-review.sh` | Codex レビューを1周実行し、対応必須の指摘の有無を返す。指摘への反論も投げられる | ほぼ汎用。4周上限だけがこのフローの方針 |
| `preflight-gates.sh` | build / unit test / ktlint を順に実行する | 汎用。push 前チェックとして単体でも使える |
| `ktlint-diff.mjs` | ktlint の違反のうち「追加行」に該当するものだけを抽出する | 汎用。`preflight-gates.sh` から呼ばれる |
| `gh-project-status.sh` | GitHub Projects (v2) の Status を Issue / PR に設定する | 汎用。Projects を使う場面ならどこでも |
| `tests/run-tests.sh` | 上記のテストを実行する | — |

呼び出し関係は `preflight-gates.sh` → `ktlint-diff.mjs` の1本だけ。
`codex-review.sh` と `gh-project-status.sh` は他のスクリプトに依存しない。

---

## `codex-review.sh`

Codex レビューを1周実行し、対応必須の指摘があるかを終了コードで返す。

```bash
codex-review.sh --check                  # Codex が使えるかだけ確認する
codex-review.sh --round <N> --base <ref> # レビューを1周実行する
codex-review.sh --discuss <message>      # 指摘に反論して見解を求める（ラウンドを消費しない）
```

`openai-codex/codex` プラグインの共有ランタイム（`codex-companion.mjs adversarial-review`）を
経由して Codex を呼ぶ。プラグインの場所は `CODEX_COMPANION` → バージョン glob の順で解決し、
バージョンはハードコードしない。

レビュー基準は focus text で明示的に渡す（リポジトリに `AGENTS.md` が無く、Codex は
`CLAUDE.md` を自動では読まないため）。

### 終了コード

| code | 意味 |
|---|---|
| 0 | 対応必須（`critical` / `high`）の指摘なし / `--discuss` が見解を取得した |
| 10 | 対応必須の指摘あり |
| 20 | `--round` が上限（4）を超えた |
| 30 | Codex が使えない（companion 不在・未認証） |
| 1 | 実行失敗 |

### `--discuss`

Codex の指摘が誤っていると考えたときに、反論して見解を求める。

**`--round` を取らず `findings-<N>.json` も書き換えない。** そのため何回使っても
レビューのラウンド数は増えない。「ディスカッションはループ回数に数えない」という規則を、
運用の約束ではなくインターフェースの形で保証している。

**`10` は返さない。** 指摘を採るか採らないかの判断は呼び出し側の仕事で、このコマンドは
見解を取得できたかどうかだけを返す。

レビュー本体（`adversarial-review`）のスレッドは task 履歴に残らず
`task --resume-last` では継続できないため、`task --fresh` で毎回新しいスレッドを立てる。
Codex は前の文脈を持たないので、**指摘の全文と該当コードを message に含めること**。
前の結論に引きずられない分、二次意見としてはむしろ素直に働く。

やりとりは findings ディレクトリの `discussion.md` に追記される。

`severity` が既知の4値（`critical` / `high` / `medium` / `low`）以外、または欠落している
指摘は**対応必須**として扱う（fail closed）。判定をすり抜けさせないため。

### 出力

各ラウンドの指摘は `<repo-root>/.git/gh-fix-issue/findings-<N>.json` に保存される。
`.git/` 配下に置くのは成果物としてコミットされないようにするため。
`--round 1` の実行時にディレクトリを作り直すので、前回の実行結果は残らない。

### 環境変数

| 変数 | 用途 | 未設定時 |
|---|---|---|
| `CODEX_COMPANION` | `codex-companion.mjs` のパスを固定する | `~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs` のうち最新版 |
| `GH_FIX_ISSUE_FINDINGS_DIR` | findings の保存先を変える | `<repo-root>/.git/gh-fix-issue` |
| `CODEX_REVIEW_FIXTURE` | **テスト専用。** Codex を呼ばず、指定した JSON を判定結果として使う | 未使用（実際に Codex を呼ぶ） |
| `CODEX_REVIEW_DISABLE_GLOB` | **テスト専用。** `CODEX_COMPANION` が不正なとき glob へフォールバックさせない | フォールバックする |

`CODEX_REVIEW_FIXTURE` が設定されていると標準エラー出力に警告を出す。
**この状態で得た「合格」は実際にはレビューされていない。**

---

## `preflight-gates.sh`

push 前のゲート。設定されたゲートを順に実行し、途中で失敗しても後続を止めない
（すべての不合格を集める）。

```bash
preflight-gates.sh [--base <ref>]   # 引数なしなら base は設定の GH_FIX_ISSUE_BASE_BRANCH
                                    # 設定が無ければ origin/HEAD → gh repo view で解決
                                    # 解決できなければ exit 1（main に決め打たない）
```

**`<リポジトリルート>/.claude/gh-fix-issue.gates.sh` があれば、それに委譲して終了コードを
そのまま返す。** 上書きファイルはプラグインごとに独立しており（命名パターン
`.claude/<プラグイン名>.gates.sh` は共通。`docs/plugin-distribution.md` §5）、
他プラグインのファイルには反応しない。委譲時は以下のゲート定義や lint 判定は行わない。

| ゲート | 実行内容 |
|---|---|
| ビルド / テスト | 設定 `GH_FIX_ISSUE_GATES` に列挙されたコマンドを順に実行 |
| lint | 設定 `GH_FIX_ISSUE_LINT_CMD` を実行した後、`ktlint-diff.mjs` で追加行の違反だけを判定 |

ゲートの中身は `<リポジトリルート>/.claude/gh-fix-issue.config.sh` が定義し、
`GH_FIX_ISSUE_BUILD_DIR` で実行する（Git リポジトリルートとビルドルートが
異なる構成に対応するため）。

`--base` 以外の引数、値の欠けた `--base` はエラーで停止する。
黙って `develop` にフォールバックすると比較対象がずれ、ktlint の判定自体が狂うため。

### 終了コード

| code | 意味 | 対処 |
|---|---|---|
| 0 | 全ゲート合格 | — |
| 10 | いずれかが不合格 | 標準エラー出力の `不合格のゲート:` に原因が出る。直して再実行する |
| 1 | ゲートの実行基盤自体が失敗 | **「直して再実行」の対象ではない。** 結果全体が信用できない |

exit 1 になるのは、ktlint タスク自体が失敗した場合や、`ktlint-diff.mjs` が実行エラーを
返した場合。このとき先行するビルド／テストが既に失敗していても、その `FAILED` 表示は
標準出力側に出たまま埋もれる。停止して報告する際は両方を見ること。

### 環境変数

| 変数 | 用途 | 未設定時 |
|---|---|---|
| `PREFLIGHT_GRADLE` | `gradlew` の代わりに使うコマンド（設定側のコマンド内で参照される差し替え口） | 設定に従う |
| `PREFLIGHT_SKIP_KTLINT` | **テスト専用。** ktlint ゲートを丸ごと飛ばす | 実行する |
| `PREFLIGHT_KTLINT_REPORT_DIR` | ktlint レポートの探索先を変える | `GH_FIX_ISSUE_LINT_REPORT_DIR` の値 |
| `PREFLIGHT_KTLINT_DIFF_FILE` | `--base` の代わりに diff ファイルを `ktlint-diff.mjs` へ渡す | `--base` を使う |

`PREFLIGHT_SKIP_KTLINT` が設定されていると標準エラー出力に警告を出し、
サマリ行にもスキップしたゲート名を出す。**この状態の exit 0 は ktlint を検証していない。**

---

## `ktlint-diff.mjs`

ktlint の CHECKSTYLE レポートと `git diff` を突き合わせ、
**変更ファイル かつ 追加行**に該当する違反だけを報告する。

```bash
node ktlint-diff.mjs --report-dir <dir> --base <ref> [--diff-file <path>] [--repo-root <path>]
```

こういう作りになっているのは2つの制約のため。

1. Gradle 側で `ktlint { ignoreFailures.set(true) }` になっているリポジトリでは、
   `ktlintCheck` は違反があっても終了コード 0 を返す。終了コードはゲートに使えない
2. プロジェクト全体に既存違反が多数あるリポジトリでは、変更ファイルの違反を全部拾うと
   ゲートは常に赤になる

### 終了コード

| code | 意味 |
|---|---|
| 0 | 追加行に違反なし |
| 10 | 追加行に違反あり |
| 1 | 実行失敗 |

exit 1 になるのは、`--report-dir` に XML が1つも無い場合と、
`--repo-root` が checkstyle の絶対パスと噛み合っていない場合。
どちらも「検査できていない」状態であり、「違反ゼロ」と区別する必要がある。

`--repo-root` の整合判定は diff の内容に依存しない（相対化した結果が
リポジトリ外を指すかどうかで見る）。そのため diff が空でも、Kotlin を1つも
触っていない変更でも、誤って失敗にはならない。

---

## `gh-project-status.sh`

GitHub Projects (v2) の Status を Issue / PR に設定する。

```bash
gh-project-status.sh --check
gh-project-status.sh --issue <N> --project <名前> --status <名前> [--dry-run]
gh-project-status.sh --pr <N>    --project <名前> --status <名前> [--dry-run]
```

このリポジトリで使われている Project と Status:

| Project | 対象 | Status の選択肢 |
|---|---|---|
| Android Issues | Issue（自動追加） | 🆕 New / 📋 Backlog / 🔖 Ready / 🏗 In progress / 👀 In review / 💮 Reviewed / 🔍 Ready for QA / 🕵🏻 In QA / ✅ Done |
| Android Pull Requests | PR（自動追加） | Todo / In Progress / Done |

Mobile 側にも同名構成の Project（Mobile Issues / Mobile Pull Requests）があるが、
`/gh-fix-issue` は Android 側だけを更新する。

### 終了コード

| code | 意味 |
|---|---|
| 0 | 設定できた（`--dry-run` なら解決できた） |
| 30 | gh トークンに `project` スコープが無い |
| 1 | 実行失敗（Project 名・Status 名が見つからない、API エラーなど） |

`project` スコープは既定では付いていない。無い場合は次で付与する。

```bash
gh auth refresh -h github.com -s project
```

### 名前解決について

Project ID・フィールド ID・選択肢 ID は**実行時に名前から解決する**。
ハードコードすると Project の選択肢が編集された瞬間に壊れ、しかも
「Status が変わらないだけ」で気づけないため。

Status 名は完全一致で探し、見つからなければ**絵文字と大小文字を無視して**再照合する。
同じ組織内でも表記が揺れているため（Android Issues は `🏗 In progress`、
Android Pull Requests は `In Progress`）。複数の選択肢に一致した場合はエラーで停止する。

### 環境変数

| 変数 | 用途 | 未設定時 |
|---|---|---|
| `GH_PROJECT_ITEMS_FIXTURE` | **テスト専用。** `projectItems` クエリの応答を差し替える。設定時は実際の mutation も投げない | 実 API を呼ぶ |
| `GH_PROJECT_FIELDS_FIXTURE` | **テスト専用。** フィールド一覧クエリの応答を差し替える | 実 API を呼ぶ |

---

## `tests/run-tests.sh`

`tests/test-*.sh` を順に読み込んで実行し、通過数と失敗数を集計する。
すべて通れば終了コード 0。

```bash
bash .claude/scripts/tests/run-tests.sh
```

bats は使わない（未インストールのため）。素の bash で、`assert_eq` と `assert_contains` の
2つのヘルパだけを提供する。テストファイルはこのヘルパと `$SCRIPTS_DIR` / `$TESTS_DIR` を
前提に書く。

テストは実 Codex も実 Gradle も呼ばない。上の表にある「テスト専用」の環境変数と
`tests/fixtures/` の固定データで各経路を再現する。findings の保存先もテスト用の
一時ディレクトリへ逃がしているので、本番の `.git/gh-fix-issue/` を汚さない。

テストを追加するときは `tests/test-<対象>.sh` を作れば自動で拾われる。
