# external-review

A Claude Code plugin that gets an independent code review from an external AI
reviewer — Codex CLI first, falling back to GitHub Copilot CLI if Codex fails —
for pending/uncommitted changes, a whole branch, a diff against a base ref, or an
arbitrary commit range. Never a same-vendor subagent reviewing its own work.

Whether and when this runs automatically (e.g. before every commit) is a policy
call for *your* project, not something this plugin decides — see Usage below.

## Install

In Claude Code:

```
/plugin marketplace add tatat/external-review
/plugin install external-review@external-review
```

Requirements: at least one of [Codex CLI](https://developers.openai.com/codex/cli)
or [GitHub Copilot CLI](https://github.com/features/copilot/cli), installed and
authenticated — either alone is enough to get a review; having both just adds the
fallback safety net if one has a transient failure. Run `/external-review:setup`
once to check/install both and register a permission rule so review invocations
don't prompt for confirmation every time.

## Usage

The `external-review` skill reviews pending/uncommitted changes, a whole branch, a
diff against a base ref, or an arbitrary commit range. It:

1. Runs `codex exec --sandbox read-only --ephemeral` against whatever's in scope.
2. Falls back to Copilot CLI if Codex fails, diagnosing setup gaps vs. transient
   failures along the way.
3. Applies trivial/clearly-correct fixes silently; surfaces significant findings for
   you to decide on; never substitutes a same-model-family subagent as a stand-in
   reviewer if both fail.

Whether and when this runs automatically (e.g. before every commit that touches
behavior or configuration) and what, if anything, is exempt are policy calls for
*your* project, not something this plugin decides. Document your policy in your
project's own AGENTS.md/CLAUDE.md; without one, Claude will ask rather than assume.
Say "skip review" / "just commit" for a one-off exemption regardless of policy.

## Structure

- `skills/external-review/SKILL.md` — the skill itself: how to invoke each reviewer,
  how to diagnose/handle failures, and how to act on feedback.
- `skills/external-review/scripts/run-codex-review.sh` /
  `run-copilot-review.sh` — the two reviewer wrappers, each with a no-recursion
  preamble so the reviewer doesn't try to review its own review.
- `skills/setup/SKILL.md` — one-time environment prep: installs/checks both CLIs,
  prompts for login if needed, and registers a Bash permission allow-rule.
- `.claude-plugin/` — plugin + marketplace manifests (this repo can be added
  directly as a marketplace source — see Install above).

See `CLAUDE.md` for implementation conventions and `TODO.md` for deliberately
deferred ideas.
