---
name: setup
description: "Set up and verify the environment for the external-review skill — installs/checks Codex CLI and GitHub Copilot CLI, prompts for login if needed, and registers a permission rule so review invocations don't prompt for confirmation every time. Run this once per environment, or whenever external-review invocations keep asking for confirmation despite the CLIs being installed and authenticated."
---

# external-review setup

One-time environment prep for the `external-review` skill. Every step is idempotent —
check before acting, and skip anything already satisfied.

## 1. Codex CLI

Check: `command -v codex`.

- If already installed (however it got there — brew, the official installer,
  anything else), leave it alone. Don't reinstall it or switch install methods just
  because a different one is documented here.
- Only if genuinely missing, install via OpenAI's official installer:
  `curl -fsSL https://chatgpt.com/codex/install.sh | sh` (installs a standalone binary,
  typically at `~/.local/bin/codex`).
- Check auth with `codex login status`. If not logged in, login is interactive
  (browser-based) — ask the user to run `codex login` themselves (e.g. suggest typing
  `!codex login` in the prompt). Don't attempt this yourself.

## 2. GitHub Copilot CLI

Check: `command -v copilot`.

- If already installed (however it got there — brew, the official installer,
  anything else), leave it alone. Don't reinstall it or switch install methods just
  because a different one is documented here.
- Only if genuinely missing, install via GitHub's official installer:
  `curl -fsSL https://gh.io/copilot-install | bash` (installs to `~/.local/bin/copilot`).
- There's no dedicated `copilot login status` subcommand. Check auth with a
  constrained, tool-less probe — **not** `--allow-all-tools`, which would turn a
  login check into a fully tool-enabled agent run in whatever directory this
  happens to be invoked from:
  `copilot -p "reply with OK" --available-tools= --no-custom-instructions --silent --no-auto-update`
  (`--available-tools=` with nothing after `=` disables every tool, so it can only
  reply directly; `--no-custom-instructions` skips loading any repo-level
  instructions too). If it errors with something indicating no credentials (rather
  than answering "OK"), login is interactive — ask the user to run `copilot login`
  themselves, same as Codex.

## 3. Permission rule so review invocations don't prompt every time

`external-review`'s two scripts (`run-codex-review.sh`, `run-copilot-review.sh`) take
the review prompt as a **file-path argument**, specifically so their invocation is a
fixed, unvarying command that a Bash permission allow-rule can match (see that skill's
own SKILL.md/TODO.md for why — a heredoc/stdin approach can't be allow-listed at all,
confirmed empirically). Nothing registers that rule automatically, so without this
step every single review invocation prompts for confirmation.

1. Determine the absolute path of **this** skill's own directory (the directory
   containing this SKILL.md — same method `external-review`'s own SKILL.md describes:
   from how you discovered this file, not a hardcoded guess). Call it `<setup-dir>`.
2. The `external-review` skill is always installed as `<setup-dir>`'s sibling
   directory, regardless of install method (personal `~/.claude/skills/`, project
   `.claude/skills/`, or a plugin cache path) — both ship from the same
   `skills/` parent. So its scripts are at:
   - `<setup-dir>/../external-review/scripts/run-codex-review.sh`
   - `<setup-dir>/../external-review/scripts/run-copilot-review.sh`

   Resolve both to absolute, `..`-free paths in **two** forms, since either could be
   the one actually typed when `external-review` gets invoked (this repo's own
   dogfooding setup, for instance, reaches both skills through `.claude/skills/`
   symlinks): the **logical** path (`cd` into the directory, then plain `pwd` —
   follows symlinks but keeps their names in the result) and the **physical** path
   (`pwd -P`, or `realpath`/`readlink -f` — fully symlink-resolved). If the two
   differ, register a rule for *both* in the next step; a permission rule matches
   literal path text, so registering only one form risks not matching whichever
   form the other invocation actually uses.
3. Read `~/.claude/settings.json` (create `{}` if it doesn't exist yet). Add, under
   `permissions.allow` (merge with whatever's already there — **never** overwrite
   the array), one entry per script per path form from step 2:
   - `Bash(<abs-path-to-run-codex-review.sh> *)`
   - `Bash(<abs-path-to-run-copilot-review.sh> *)`
   - (plus the physical-path variants of both, if they differed from the logical
     ones)

   Use **global** `~/.claude/settings.json` here, not a project's
   `.claude/settings.local.json` — the scripts' own path doesn't change based on which
   repo you're reviewing, so a project-scoped rule would need re-registering in every
   project you ever run a review from. Skip any entry that's already present
   (idempotent — don't add duplicates).
4. Validate the JSON after editing (e.g. `jq empty ~/.claude/settings.json`) before
   finishing — a malformed settings file silently disables everything else in it.
5. If you just edited this mid-session (not at the very start of a fresh session),
   the change may not take effect immediately — Claude Code's settings watcher only
   picks up files/directories that existed when the session started. Tell the user
   they may need to run `/hooks` once (reloads config) or start a new session before
   the rule takes effect; you can't do either yourself.

## Where this doesn't help

This only covers the **Bash** confirmation for invoking the scripts themselves. It
does not do anything about the separate, one-off **Write** confirmation that appears
the first time in a session if the calling agent writes the review prompt file outside
the current project (see `external-review`'s SKILL.md, option 3) — that grant is
session-scoped only and, per already-confirmed testing, cannot be made to persist
across sessions no matter how it's registered. Prefer the calling agent write the
prompt file inside the target repo instead (options 1 or 2 in that SKILL.md) if
avoiding that confirmation entirely matters.
