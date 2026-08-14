# external-review

A Claude Code plugin that gets an independent review of your pending (uncommitted)
changes from an external AI reviewer before you commit — Codex CLI first, falling
back to GitHub Copilot CLI if Codex fails. Never a same-vendor subagent reviewing
its own work.

## Install

In Claude Code:

```
/plugin marketplace add tatat/external-review
/plugin install external-review@external-review
```

Requirements: [Codex CLI](https://developers.openai.com/codex/cli) and/or
[GitHub Copilot CLI](https://github.com/features/copilot/cli), installed and
authenticated. Run `/external-review:setup` once to check/install both and register
a permission rule so review invocations don't prompt for confirmation every time.

## Usage

The `external-review` skill runs automatically before any `git commit` that touches
behavior or configuration — no need to ask for it. It:

1. Runs `codex exec --sandbox read-only --ephemeral` against your pending changes.
2. Falls back to Copilot CLI if Codex fails, diagnosing setup gaps vs. transient
   failures along the way.
3. Applies trivial/clearly-correct fixes silently; surfaces significant findings for
   you to decide on; never substitutes a same-model-family subagent as a stand-in
   reviewer if both fail.

Skipped only for pure documentation typos or dependency-only version bumps — unless
you explicitly ask for a review.

## Structure

- `skills/external-review/SKILL.md` — the skill itself: when to review, how to
  invoke each reviewer, how to diagnose/handle failures, skip criteria, and how to
  act on feedback.
- `skills/external-review/scripts/run-codex-review.sh` /
  `run-copilot-review.sh` — the two reviewer wrappers, each with a no-recursion
  preamble so the reviewer doesn't try to review its own review.
- `skills/setup/SKILL.md` — one-time environment prep: installs/checks both CLIs,
  prompts for login if needed, and registers a Bash permission allow-rule.
- `.claude-plugin/` — plugin + marketplace manifests (this repo can be added
  directly as a marketplace source — see Install above).

See `CLAUDE.md` for implementation conventions and `TODO.md` for deliberately
deferred ideas.
