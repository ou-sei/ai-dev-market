# ai-dev-market

[English](README.md) | 日本語 | [简体中文](README.zh-CN.md)

**Codex や Claude、Gemini、Grokなど AI を活用して、エンジニアの日常開発に役立つツール・
プラグインを提供するマーケットプレイス。** 特定の AI ツール専用にはせず、対応先は
今後も増やしていく。現時点の配布形態は Claude Code プラグイン（コマンドとスキル）。

## 何が入っているか

| ツール | 内容 |
|---|---|
| `gh-fix-issue` | GitHub Issue 番号 1 つで、Issue 取得 → 実装 → セルフレビュー → Codex レビュー → ゲート → PR 作成 までを通す |
| `gh-fix-review` | GitHub PR の Review comment を取得し、各指摘の妥当性を判断 → 対応 → ゲート → push → **各スレッドへ必ずインライン返信**する |

`gh-fix-issue` は Issue から PR を作る側、`gh-fix-review` は既にある PR の
レビュー指摘に対応する側。**それぞれ単独で導入して使える。**

## どの AI が何をするか

**実装者とレビュアーを別の AI に分ける**のがこのツール群の核。

| 段階 | 担当 |
|---|---|
| Issue 取得・実装・セルフレビュー・コミット・PR 作成・指摘対応 | **Claude Code**（コマンド / スキルを実行している本体） |
| 敵対的レビュー（`gh-fix-issue` のレビューループ） | **Codex**（独立した二次意見。実装した AI 自身のセルフレビューだけで通さない） |
| ゲート（ビルド・テスト・lint）とスレッド返信の実行 | **素のシェルスクリプト**（AI ではなく決定的。終了コードだけで判定する） |

## 前提条件

いずれも**ローカルで実行する**ツール。事前に次を用意する。

| 前提 | `gh-fix-issue` | `gh-fix-review` |
|---|---|---|
| Claude Code（実行ホスト） | 必須 | 必須 |
| `gh` CLI（`gh auth login` 済み） | 必須 | 必須 |
| Codex CLI + `openai-codex/codex` プラグイン | **必須** | 不要 |
| node | lint ゲートを使う場合のみ | 不要 |

`gh-fix-issue` は開始時に Codex の疎通を確認し、使えなければ**停止して
`/codex:setup` を案内する**（動かしてから気づく事故は起きない）。
`gh-fix-review` は Codex を一切使わない。

## 導入

```bash
claude plugin marketplace add ou-sei/ai-dev-market
claude plugin install gh-fix-issue@ai-dev-market
claude plugin install gh-fix-review@ai-dev-market
```

private リポジトリのままで動く。`marketplace add` の実体は `git clone` なので、
このリポジトリへの git 認証があれば読める。

**まとめて入れる仕組みは無い。** プラグインが他のプラグインへの依存を宣言する
仕組みが無いため、必要なものを 1 つずつ指定する。

### 更新

**2 段構えで、最後に再起動が必要。**

```bash
claude plugin marketplace update ai-dev-market          # marketplace の情報を取り直す
claude plugin update gh-fix-issue@ai-dev-market          # プラグイン本体を更新する
claude plugin update gh-fix-review@ai-dev-market
```

`marketplace update` だけではプラグイン本体は更新されない（`install` は
`already installed` と言って何もしない）。`plugin update` には
`<名前>@<marketplace>` の形が必要で、名前だけだと `Plugin not found` になる。
更新後は **Claude Code の再起動**で反映される。

`claude plugin install` にバージョン指定の構文は無い。利用者は常に
marketplace が指すバージョンを取る。詳細は `docs/plugin-distribution.md` §6。

## 構成

```
ai-dev-market/
├── .claude-plugin/marketplace.json     プラグイン一覧
├── plugins/
│   ├── gh-fix-issue/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── commands/gh-fix-issue.md
│   │   └── scripts/                    codex-review / preflight-gates / ktlint-diff /
│   │                                   gh-project-status / gh-fix-issue-config / tests
│   └── gh-fix-review/
│       ├── .claude-plugin/plugin.json
│       └── skills/gh-fix-review/     SKILL.md / pr-reply.sh / threads.jq / tests
├── tests/                              リポジトリ全体の整合を見る検証
└── docs/
    ├── gh-fix-issue.md
    ├── gh-fix-review.md
    └── plugin-distribution.md          配布方式の設計。新しいツールの追加手順もここ
```

**プラグインは他のプラグインを参照しない。** 片方だけ入れた人が壊れないようにするため。

同梱ファイルの参照には `${CLAUDE_PLUGIN_ROOT}` を使う。`~/.claude/...` の絶対パスは
プラグイン化すると存在しない。

## 利用リポジトリ側に必要なもの

リポジトリ側の準備は**すべて任意**。push 前の検証を上書きしたい場合だけ、
プラグインごとに独立したファイルを置く（片方の設定がもう片方の動作を変えないため）。

| プラグイン | 上書きファイル | 無い場合の既定 |
|---|---|---|
| `gh-fix-issue` | `.claude/gh-fix-issue.gates.sh` | `.claude/gh-fix-issue.config.sh` のゲート定義（無ければゲート無し） |
| `gh-fix-review` | `.claude/gh-fix-review.gates.sh` | プロジェクト形式を自動検出（`gradlew test` / `npm test` など） |

上書きファイルの終了コードの契約は共通。

| exit | 意味 |
|---|---|
| 0 | 合格 |
| 10 | 不合格。直して再実行 |
| 1 | ゲートの実行基盤の問題。直して再実行せず停止 |

上書きファイルは**どのプラグインにも依存させない**。プラグインのキャッシュを辿る
ラッパーにすると、片方しか入れていない人が壊れる。

`gh-fix-issue` / `gh-fix-review` とも、実際の Android リポジトリで実地検証済み。

## 新しいツールを追加する

`docs/plugin-distribution.md` §8 の手順に従う。`plugins/` にディレクトリを作り、
`marketplace.json` に登録する。**登録を忘れると誰にも配布されない**ので CI が対応を検証する。

## 開発

ローカルの作業ツリーをそのままマーケットプレイスとして追加できる。

```bash
claude plugin marketplace add /path/to/ai-dev-market
```

テストは CI が `plugins/**/tests/run-tests.sh` を発見して実行する。手元で回すには
そのパスを直接叩く。

manifest の整合は `python3 tests/check-manifests.py` で見る。組み込みの
`claude plugin validate` も使えるが、**`plugins/` にあるのに `marketplace.json` に
未登録のディレクトリを検出しない**（実測で確認）。この登録漏れが一番気づけない
失敗なので、自前の検証を CI に置いている。`claude` CLI は GitHub runner に無いため
CI では組み込みコマンドを使えない、という理由もある。
