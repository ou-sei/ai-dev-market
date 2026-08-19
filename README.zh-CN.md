# ai-dev-market

[English](README.md) | [日本語](README_ja.md) | 简体中文

**利用 Codex、Claude、Gemini、Grok 等 AI，为工程师的日常开发提供实用工具与插件的
marketplace。** 不绑定任何特定的 AI 工具，支持范围今后会持续扩大。目前的分发形式是
Claude Code 插件（command 与 skill）。

## 包含内容

| 工具 | 说明 |
|---|---|
| `gh-fix-issue` | 只需一个 GitHub Issue 编号，即可完成 获取 Issue → 实现 → 自我评审 → Codex 评审 → 门禁 → 创建 PR 的全流程 |
| `gh-fix-review` | 获取 PR 的 Review comment，逐条判断其合理性 → 修改 → 门禁 → push → **并且必须对每个线程进行内联回复** |

`gh-fix-issue` 负责从 Issue 创建 PR；`gh-fix-review` 负责处理既有 PR 的评审意见。
**两者都可以单独安装、独立使用。**

## 各阶段由哪个 AI 负责

这套工具的核心是**把实现者和评审者分给不同的 AI**。

| 阶段 | 负责方 |
|---|---|
| 获取 Issue、实现、自我评审、提交、创建 PR、处理评审意见 | **Claude Code**（执行 command / skill 的本体） |
| 对抗性评审（`gh-fix-issue` 的评审循环） | **Codex**（独立的第二意见——不允许只靠实现方 AI 的自我评审就通过） |
| 门禁（构建 / 测试 / lint）与线程回复的执行 | **纯 Shell 脚本**（确定性执行而非 AI，只按退出码判定） |

## 前置条件

两个工具都是**本地运行**的。请提前准备以下环境。

| 前置条件 | `gh-fix-issue` | `gh-fix-review` |
|---|---|---|
| Claude Code（运行宿主） | 必需 | 必需 |
| `gh` CLI（已 `gh auth login`） | 必需 | 必需 |
| Codex CLI + `openai-codex/codex` 插件 | **必需** | 不需要 |
| node | 仅在使用 lint 门禁时 | 不需要 |

`gh-fix-issue` 在启动时会先确认 Codex 可用性，不可用时会**停止并引导执行
`/codex:setup`**（不会跑到一半才发现）。`gh-fix-review` 完全不使用 Codex。

## 安装

```bash
claude plugin marketplace add ou-sei/ai-dev-market
claude plugin install gh-fix-issue@ai-dev-market
claude plugin install gh-fix-review@ai-dev-market
```

仓库保持 private 也能正常使用。`marketplace add` 的实质是 `git clone`，
只要拥有本仓库的 git 访问权限即可读取。

**没有批量安装的机制。** 插件之间无法声明依赖关系，因此需要逐个指定所需的插件。

### 更新

**分两步，最后需要重启。**

```bash
claude plugin marketplace update ai-dev-market          # 刷新 marketplace 信息
claude plugin update gh-fix-issue@ai-dev-market         # 更新插件本体
claude plugin update gh-fix-review@ai-dev-market
```

仅执行 `marketplace update` 不会更新插件本体（`install` 只会提示 `already installed`
而不做任何事）。`plugin update` 必须使用 `<名称>@<marketplace>` 的形式，只写名称会报
`Plugin not found`。更新后需要**重启 Claude Code** 才能生效。

`claude plugin install` 没有指定版本的语法，用户始终获取 marketplace 所指向的版本。
详见 `docs/plugin-distribution.md` §6。

## 目录结构

```
ai-dev-market/
├── .claude-plugin/marketplace.json     插件清单
├── plugins/
│   ├── gh-fix-issue/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── commands/gh-fix-issue.md
│   │   └── scripts/                    codex-review / preflight-gates / ktlint-diff /
│   │                                   gh-project-status / gh-fix-issue-config / tests
│   └── gh-fix-review/
│       ├── .claude-plugin/plugin.json
│       └── skills/gh-fix-review/       SKILL.md / pr-reply.sh / threads.jq / tests
├── tests/                              仓库整体一致性校验
└── docs/
    ├── gh-fix-issue.md
    ├── gh-fix-review.md
    └── plugin-distribution.md          分发方式的设计；新增工具的步骤也在这里
```

**插件之间互不引用。** 以保证只安装其中一个插件的用户不会被破坏。

引用随插件分发的文件时使用 `${CLAUDE_PLUGIN_ROOT}`。打包成插件后，
`~/.claude/...` 形式的绝对路径并不存在。

## 使用方仓库需要准备什么

仓库侧的准备**全部可选**。只有想覆盖 push 前的校验时，才按插件分别放置一个文件
（保证一个插件的配置不会改变另一个插件的行为）。

| 插件 | 覆盖文件 | 缺省行为 |
|---|---|---|
| `gh-fix-issue` | `.claude/gh-fix-issue.gates.sh` | 使用 `.claude/gh-fix-issue.config.sh` 中定义的门禁（没有则无门禁） |
| `gh-fix-review` | `.claude/gh-fix-review.gates.sh` | 自动检测项目类型（`gradlew test` / `npm test` 等） |

覆盖文件共用同一套退出码约定：

| exit | 含义 |
|---|---|
| 0 | 通过 |
| 10 | 不通过。修复后重跑 |
| 1 | 门禁运行环境本身的问题。停止，不属于修复重跑的范畴 |

覆盖文件**不得依赖任何插件**。写成去插件缓存里找脚本的 wrapper，
会破坏只安装了其中一个插件的用户。

`gh-fix-issue` / `gh-fix-review` 均已在真实的 Android 仓库中实地验证。

## 新增工具

按照 `docs/plugin-distribution.md` §8 的步骤：在 `plugins/` 下创建目录，
并登记到 `marketplace.json`。**忘记登记的工具不会分发给任何人**，
因此由 CI 校验两者的对应关系。

## 开发

本地工作树可以直接作为 marketplace 添加。

```bash
claude plugin marketplace add /path/to/ai-dev-market
```

CI 会自动发现并执行所有 `plugins/**/tests/run-tests.sh`。本地验证时直接执行这些路径即可。

manifest 的一致性用 `python3 tests/check-manifests.py` 检查。内置的
`claude plugin validate` 也可用，但**无法检测「`plugins/` 下存在、却未登记到
`marketplace.json`」的目录**（实测确认）。这种遗漏最难被发现，所以在 CI 中放了
自研校验；另外 GitHub runner 上没有 `claude` CLI，CI 中也无法使用内置命令。
