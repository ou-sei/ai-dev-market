# ai-dev-market

English | [日本語](README_ja.md) | [简体中文](README.zh-CN.md)

**A marketplace of tools and plugins that leverage AI — Codex, Claude, Gemini, Grok, and more —
to help engineers with their day-to-day development.** It is not tied to any single AI tool,
and the list of supported ones will keep growing. The current distribution format is
Claude Code plugins (commands and skills).

## What's inside

| Tool | Description |
|---|---|
| `gh-fix-issue` | From a single GitHub Issue number, runs the whole flow: fetch the Issue → implement → self-review → Codex review → gates → create the PR |
| `gh-fix-review` | Fetches PR review comments, judges the validity of each → fixes → gates → push → **always replies inline to every thread** |

`gh-fix-issue` creates a PR from an Issue; `gh-fix-review` handles review feedback on an
existing PR. **Each can be installed and used on its own.**

## Which AI does what

The core idea of these tools is to **separate the implementer and the reviewer into
different AIs**.

| Stage | Actor |
|---|---|
| Fetching the Issue, implementation, self-review, commits, PR creation, addressing feedback | **Claude Code** (the host running the command / skill) |
| Adversarial review (the review loop of `gh-fix-issue`) | **Codex** (an independent second opinion — the implementing AI's self-review alone is never enough to pass) |
| Gates (build / test / lint) and posting thread replies | **Plain shell scripts** (deterministic, not AI; judged by exit codes only) |

## Prerequisites

Both tools **run locally**. Prepare the following in advance.

| Prerequisite | `gh-fix-issue` | `gh-fix-review` |
|---|---|---|
| Claude Code (the host) | Required | Required |
| `gh` CLI (after `gh auth login`) | Required | Required |
| Codex CLI + the `openai-codex/codex` plugin | **Required** | Not needed |
| node | Only if you use the lint gate | Not needed |

`gh-fix-issue` verifies Codex connectivity at startup and, if unavailable, **stops and
points you to `/codex:setup`** (so you never find out mid-run). `gh-fix-review` does not
use Codex at all.

## Installation

```bash
claude plugin marketplace add ou-sei/ai-dev-market
claude plugin install gh-fix-issue@ai-dev-market
claude plugin install gh-fix-review@ai-dev-market
```

Works with the repository kept private. `marketplace add` is effectively a `git clone`,
so anyone with git authentication for this repository can read it.

**There is no bulk-install mechanism.** Plugins cannot declare dependencies on other
plugins, so install the ones you need one by one.

### Updating

**Two steps, then a restart.**

```bash
claude plugin marketplace update ai-dev-market          # refresh the marketplace info
claude plugin update gh-fix-issue@ai-dev-market         # update the plugin itself
claude plugin update gh-fix-review@ai-dev-market
```

`marketplace update` alone does not update the plugins themselves (`install` just says
`already installed` and does nothing). `plugin update` requires the `<name>@<marketplace>`
form; the name alone yields `Plugin not found`. Updates take effect after
**restarting Claude Code**.

`claude plugin install` has no syntax for pinning a version. Users always get whatever
version the marketplace points to. See `docs/plugin-distribution.md` §6 for details.

## Layout

```
ai-dev-market/
├── .claude-plugin/marketplace.json     plugin catalog
├── plugins/
│   ├── gh-fix-issue/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── commands/gh-fix-issue.md
│   │   └── scripts/                    codex-review / preflight-gates / ktlint-diff /
│   │                                   gh-project-status / gh-fix-issue-config / tests
│   └── gh-fix-review/
│       ├── .claude-plugin/plugin.json
│       └── skills/gh-fix-review/       SKILL.md / pr-reply.sh / threads.jq / tests
├── tests/                              repository-wide consistency checks
└── docs/
    ├── gh-fix-issue.md
    ├── gh-fix-review.md
    └── plugin-distribution.md          distribution design; how to add a new tool
```

**Plugins never reference each other**, so installing only one never breaks anything.

Bundled files are referenced via `${CLAUDE_PLUGIN_ROOT}`. Absolute paths under
`~/.claude/...` do not exist once packaged as a plugin.

## What a consuming repository needs

Everything on the repository side is **optional**. Only when you want to override the
pre-push verification, place one file per plugin (so one plugin's setting never changes
the other plugin's behavior).

| Plugin | Override file | Default when absent |
|---|---|---|
| `gh-fix-issue` | `.claude/gh-fix-issue.gates.sh` | Gates defined in `.claude/gh-fix-issue.config.sh` (no gates if that is absent either) |
| `gh-fix-review` | `.claude/gh-fix-review.gates.sh` | Auto-detects the project type (`gradlew test` / `npm test`, etc.) |

Override files share a common exit-code contract:

| exit | Meaning |
|---|---|
| 0 | Pass |
| 10 | Fail. Fix and re-run |
| 1 | Problem in the gate infrastructure itself. Stop; not a fix-and-re-run case |

Override files must **not depend on any plugin**. A wrapper that digs into a plugin's
cache breaks users who installed only one of the plugins.

Both `gh-fix-issue` and `gh-fix-review` have been field-tested on a real Android repository.

## Adding a new tool

Follow the steps in `docs/plugin-distribution.md` §8: create a directory under `plugins/`
and register it in `marketplace.json`. **An unregistered tool is distributed to nobody**,
so CI verifies the mapping.

## Development

A local working tree can be added directly as a marketplace.

```bash
claude plugin marketplace add /path/to/ai-dev-market
```

CI discovers and runs every `plugins/**/tests/run-tests.sh`. To run them locally,
execute those paths directly.

Manifest consistency is checked with `python3 tests/check-manifests.py`. The built-in
`claude plugin validate` also works, but it **does not detect a directory that exists
under `plugins/` yet is missing from `marketplace.json`** (verified empirically). That
omission is the hardest failure to notice, which is why the custom check lives in CI —
and the `claude` CLI is not available on GitHub runners anyway, so CI cannot use the
built-in command.
