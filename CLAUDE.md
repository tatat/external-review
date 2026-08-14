# external-review

Independent AI code review (Codex CLI, falling back to GitHub Copilot CLI) of
pending changes, a branch, a base-ref diff, or a commit range. Distributed as a
Claude Code plugin (`.claude-plugin/`, skills in
`skills/external-review/` and `skills/setup/` — `.claude/skills/` symlinks to both
for dogfooding in this repo).

## Structure

- `skills/external-review/SKILL.md` — the skill instructions themselves: how to
  invoke each reviewer, how to diagnose/handle failures, and how to act on
  feedback. Whether/when to trigger this automatically and what's exempt are
  policy calls for the target project or user, not this skill.
- `skills/external-review/scripts/run-codex-review.sh` — primary reviewer. Wraps
  `codex exec --sandbox read-only --ephemeral` with a no-recursion preamble so Codex
  doesn't try to review its own review.
- `skills/external-review/scripts/run-copilot-review.sh` — fallback reviewer. Same
  no-recursion preamble, wraps `copilot --experimental --sandbox --allow-all-tools --deny-tool write`
  (`--experimental --sandbox` enable Copilot CLI's OS-level sandbox for the
  session; no custom policy is configured, so this doesn't make the target repo
  itself read-only — see TODO.md).
- `skills/setup/SKILL.md` — one-time environment prep: installs/checks Codex CLI and
  Copilot CLI, prompts the user to log in if needed, and registers a global Bash
  permission rule (`~/.claude/settings.json`) so review invocations stop prompting
  for confirmation every time.
- `.claude-plugin/plugin.json` — plugin manifest.
- `.claude-plugin/marketplace.json` — lets this repo be added directly as a
  marketplace source (`/plugin marketplace add tatat/external-review`) for personal
  installs, without needing a separate marketplace repo.

## Conventions

- Both scripts are self-contained (no shared sourcing between them) — the
  no-recursion preamble is intentionally duplicated rather than factored out, so
  each script stays a single file that's easy to read top-to-bottom.
- SKILL.md tells the invoking agent to resolve the bundled scripts to an **absolute**
  path before running them, without `cd`-ing into the skill's own directory. This
  skill's whole job is to run `codex exec`/`copilot` against whatever's in scope in
  the *target* repo, so the shell's working directory must stay at the target repo
  root — a plain path relative to the skill directory (`scripts/run-codex-review.sh`)
  would only resolve correctly by coincidence (e.g. dogfooding inside this repo) and
  otherwise either fails or silently reviews the wrong repo. (A first pass here used
  a plain relative path on the theory that the Agent Skills convention favors it —
  true for *reference* files an agent reads, but wrong for a script that must be
  *executed* from a cwd the skill doesn't control. An external review of this repo's
  own first commit caught the mistake.) No env var (`${CLAUDE_PLUGIN_ROOT}` or
  similar) is used either: it's Claude Code-specific, and SKILL.md is a portable
  format installed unmodified across a much wider ecosystem than just Claude
  Code (see e.g. `vercel-labs/skills`, which installs the same SKILL.md package
  into 75+ agent tools — Codex, Cursor, OpenCode, GitHub Copilot, etc. — via
  their own directory conventions, none of which set that variable). Depending
  on it would silently break this skill everywhere outside Claude Code's own
  plugin loader. Instead, the agent determines the skill's absolute directory
  itself from how it discovered this SKILL.md, which works identically across
  every install path: a Claude Code plugin, `~/.claude/skills/`,
  `.claude/skills/`, `.agents/skills/`, or wherever a tool like
  `vercel-labs/skills` symlinks it.
- Keep this skill's logic generic: no assumptions about a specific host project's
  file layout, doc filenames, or conventions. Anything project-specific belongs in
  the *target* repo being reviewed, not here.
- Both scripts take the review prompt as a **file path** (`<prompt-file>`), not
  stdin/a heredoc. Confirmed empirically that a heredoc whose body differs every
  invocation can never be covered by a single Bash permission allow-rule (neither
  a wildcard nor an exact-match rule suppressed the confirmation prompt); a fixed
  prompt-file path keeps the invoked command text constant, which a permission
  rule can actually match. SKILL.md documents three places to Write that file (a
  repo's own gitignored scratch convention if it has one, anywhere else in the
  repo, or outside it entirely) — see TODO.md for why no single fixed location
  won permanently. Both scripts delete `<prompt-file>` themselves right after
  reading it, before the reviewer starts, so even the "anywhere in the repo"
  option can't be mistaken for part of the diff being reviewed.
- `TODO.md` records improvements that were considered and deliberately deferred,
  with the trigger that would make each worth doing. Check it before redesigning
  something it covers; add to it when deferring a non-trivial idea.
