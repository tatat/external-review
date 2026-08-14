---
name: external-review
description: "Get an independent review of pending (uncommitted) changes from an external AI reviewer before committing — Codex CLI first, falling back to GitHub Copilot CLI if Codex fails. Use automatically before every `git commit` that touches behavior or configuration (including infra-as-code: Terraform, Dockerfiles, CI/CD); do not wait to be asked. Skip only for pure documentation typo fixes or dependency-only version bumps with no behavior change."
---

# External Code Review

Runs before `git commit` on any change that touches behavior or configuration — a
second, independent set of eyes from a different model than the one doing the
implementation.

**Never self-review.** If no reviewer is available, don't substitute a self-review and
don't commit silently — see "If both fail" below for what to do instead.

The scripts this skill uses live in `scripts/` next to this SKILL.md. Resolve that to an
**absolute path** before invoking it — e.g. `<abs-path-to-this-skill-dir>/scripts/run-codex-review.sh` —
and do **not** `cd` into the skill's directory to use a relative path instead: your
working directory needs to stay at the target repo's root, since `codex exec`/`copilot`
investigate the pending changes in whatever directory they're launched from. A plain
relative path like `scripts/run-codex-review.sh` only works by coincidence (e.g. while
developing inside this skill's own repo) and silently reviews the wrong repository, or
fails outright, everywhere else it's installed (personal `~/.claude/skills/`, a
project's `.claude/skills/`, or as an installed plugin).

Both scripts take the review prompt as a **file path**, not stdin/a heredoc — write
your prompt to a file with the Write tool first, then pass that path as the first
argument. A heredoc's body differs on every invocation, so it can never be covered by
a single Bash permission allow-rule (confirmed empirically — neither a wildcard nor an
exact-match rule suppresses the confirmation prompt when the heredoc content varies);
a fixed prompt-file path keeps the invoked command text constant, which a permission
rule can actually match.

Where to write that file — pick whichever fits this environment, in this order of
preference:

1. **The target repo's own established scratch convention, if it has one** — e.g. a
   gitignored `tmp/`/`.tmp/` directory some projects already use for throwaway files
   (check `.gitignore`). Zero Write-permission friction (it's inside the current
   project) and no contamination risk (already excluded from `git status`/`git diff`,
   so the reviewer won't see it as a pending change).
2. **Anywhere in the target repo** — if no such convention exists, write it in the
   repo (e.g. its root) anyway. Same zero Write-permission friction as above, and no
   cleanup for you to remember either: both scripts delete `<prompt-file>` themselves
   as soon as they've read it into memory, *before* invoking `codex exec`/`copilot`,
   so it's already gone by the time the reviewer inspects "pending changes."
3. **Outside the repo entirely** (e.g. `/tmp/`) — if you'd rather not touch the
   target repo's working tree even transiently. Confirmed empirically that Write
   grants for paths outside the current project are **session-scoped only**: even
   with a matching `Write(...)` rule added to the project's own
   `.claude/settings.local.json`, a fresh session still asks for confirmation once;
   choosing "allow all edits in `<dir>` during this session" avoids being asked again
   for the rest of that session, but nothing persists to any settings file across
   sessions. So this option costs one confirmation per session, in exchange for
   never touching the repo at all.

## 1. Primary reviewer: Codex CLI (direct)

Call `codex exec` directly — this gives a **fresh, unbiased read every time**, with no
carried-over assumptions from a previous review or from the implementation conversation
itself.

Use the bundled script — don't hand-write the `codex exec` invocation. Write the
prompt (see "Writing the prompt" below) to a file first, then run the script directly
(it's already executable) rather than through `bash`/`sh`:

```bash
<abs-path-to-this-skill-dir>/scripts/run-codex-review.sh <prompt-file>
```

The script runs `codex exec --sandbox read-only --ephemeral` with the prompt read
from `<prompt-file>`. `codex exec`'s own verbose transcript (every tool call it makes while
investigating) is redirected to a log file, not printed — normal output is just the
clean final message, plus a `Full trace: <path>` line on stderr. The printed final
message is normally all you need; read the log only if something looks wrong (a
suspicious finding, an empty report, a non-zero exit). The script's own exit code
reflects `codex exec`'s real result.

The script automatically prepends a fixed instruction telling Codex that it *is* the
review step and must not act on the target repo's own AGENTS.md/CLAUDE.md/skill
instructions (it has read access to that repo and would otherwise sometimes try to
recursively invoke a review of its own review, then fail on its sandboxed environment's
restrictions) — no need to add anything like that to your own prompt.

- Don't pass a model override (`<abs-path-to-this-skill-dir>/scripts/run-codex-review.sh <prompt-file> <model>`)
  unless a run fails on the account's default model — the default (`gpt-5.5` as of
  codex-cli 0.142.2, confirmed working under ChatGPT login) is fine. Some other model
  IDs 400-error under a ChatGPT login rather than an API key.
- For a large/complex diff where the review might take a while, run this same script
  call with `run_in_background: true` instead of waiting synchronously — you'll be
  notified when it completes, output included; no need to poll or manually `sleep`.

### Writing the prompt

State the requirement or outcome you need, not the literal steps to get there. The
reviewer is a competent agent with its own tools — it will work out the mechanics
itself, and dictating exact commands just goes stale and adds noise. Say "make sure
you're seeing the complete pending diff — a plain `git diff` has blind spots" rather
than "run `git status --short`, then `git diff HEAD`, then...".

Give real context, since the reviewer has no memory of this conversation:

- What changed and why (1–2 sentences of intent), so it can judge fit, not just syntax.
- What's already been considered/ruled out, so it doesn't re-raise settled questions.
- Known risk points if you have them (regex edge cases, a tricky concurrency change,
  etc.) — but leave room for it to flag things you didn't ask about too.
- The scope requirement: review only the pending/uncommitted changes, and account for
  the full diff — a plain `git diff` alone misses staged changes and won't show
  untracked files at all.

## 2. Fallback: GitHub Copilot CLI

If Codex fails, immediately run the bundled script directly (again, don't hand-write
the `copilot` invocation). Write the prompt to a **new** file and pass its path — the
file from step 1 is already gone by now (`run-codex-review.sh` deletes it right after
reading, before Codex even starts):

```bash
<abs-path-to-this-skill-dir>/scripts/run-copilot-review.sh <prompt-file>
```

The script reads the prompt from `<prompt-file>` and forwards it to
`copilot --experimental --sandbox --log-dir <dir> --model gpt-5.5 --allow-all-tools --deny-tool write --silent -p '<prompt>'`
(the model defaults to `gpt-5.5`, intended to match the current Codex CLI default
— see run-codex-review.sh, which doesn't pin a model itself — so both reviewers
run on a comparable model/cost tier; update this if Codex CLI's default changes;
`--deny-tool write` blocks the dedicated file-write tool — deny rules take
precedence over `--allow-all-tools`. `--experimental --sandbox` turn on Copilot
CLI's OS-level command sandbox for the session, but **not with a custom policy**:
under Copilot's default policy the target repo itself is still granted
read-write, so this does *not* make the review read-only for the repo being
reviewed — it only shrinks the blast radius for paths outside the repo (see
TODO.md for the full reasoning and what a real fix would need). `--experimental`
also permanently persists `"experimental": true` into the user's global
`~/.copilot/settings.json` on every invocation — a known, accepted side effect;
set `EXTERNAL_REVIEW_COPILOT_SANDBOX=0` to skip both flags and avoid it, falling
back to `--deny-tool write` alone. `--log-dir` points at a fresh, ephemeral temp
directory created per invocation by default (not Copilot's own persistent
`~/.copilot/logs/`), overridable via `EXTERNAL_REVIEW_COPILOT_LOG_DIR`. `--silent`
means the output is just the agent's response, not stats/chrome), then prints a
`Full trace: <path>` line pointing at that invocation's log — same as Codex, read
it only if something looks wrong. Same `run_in_background`
guidance as Codex: use the parameter, not a trailing `&` — combining both detaches the
process and its output is lost. Same automatic no-recursion preamble as the Codex
script, too — nothing extra to add to your own prompt.

## 3. Diagnosing a failure

When either tool fails, classify why before deciding what to do — don't just treat
"failed" as one undifferentiated state:

- **Setup gap** — the command isn't installed, isn't authenticated, or errors
  immediately with something like "not logged in" / "command not found". This is a
  standing environment problem: retrying later won't help without fixing the setup.
  Login is interactive, so ask the user to run it themselves (e.g. suggest typing
  `!<command>` in the prompt):
  - Codex: not installed → see https://developers.openai.com/codex/cli for install
    steps. Not authenticated → `codex login` (`codex login status` checks current
    state). If interactive browser-based login isn't possible in this environment
    (e.g. a headless container), check whether this project documents an
    environment-specific login workaround before giving up.
  - Copilot: not installed → see https://github.com/features/copilot/cli for install
    steps. Not authenticated → `copilot login`.
- **Transient failure** — the command runs and authenticates fine, but the request
  itself times out, or returns a 5xx / rate-limit error. This is likely to resolve on
  its own; the right move is to wait and retry later, not to treat the tool as
  permanently unavailable.

Still attempt the other reviewer regardless of which kind of failure the first one
had — a setup gap or outage in one tool says nothing about the other's availability.

## 4. If both fail

Do not substitute a subagent from the same vendor/model family as the agent doing the
implementation (e.g. a Claude subagent when Claude Code implemented the change, or a
Copilot-brand fallback when Copilot itself already failed) as a stand-in reviewer —
that isn't independent and defeats the purpose of this workflow.

Instead, pause and tell the user the specific diagnosis for each tool (setup gap vs.
transient failure, per above) and let them decide how to proceed:

- Fix the reported setup gap(s) and retry.
- Wait and retry later (for a transient failure).
- Explicitly tell you to proceed without review for this commit (see "User override" below).

Do not decide on your own to commit unreviewed code for a behavior change.

## 5. Skip criteria

Skip only for:

- Pure documentation typo fixes.
- Dependency-only version bumps (lockfile/manifest only, no functional change).

— unless the user explicitly asks for a review, which always overrides these skip
criteria.

The right test is "does this change affect behavior or configuration in any
environment?" — not "is it code". Infrastructure-as-code (Terraform, Dockerfiles,
CI/CD workflows), deployment scripts, and permission/policy changes are **not**
skip-eligible even though they might look like "just config".

## 6. User override

If the user explicitly says "skip review" / "just commit" / "no review", honor it for
that commit only — don't treat it as a standing instruction for future commits.

## 7. Handling feedback

- **Trivial / clearly correct** (typos, obvious bugs, lint-level issues, dead code):
  apply silently before commit, then mention briefly what was fixed.
- **Significant** (design questions, behavioral changes, ambiguous tradeoffs): pause,
  surface to the user, and get confirmation before proceeding.
- **False positives / disagreements**: always explain the specific reason for rejection
  ("out of scope because X", "already handled by Y", "not applicable because Z") — never
  dismiss a finding with a vague label alone.
  - Before claiming a finding is "already handled", **read the relevant file and line**
    to confirm the current code actually addresses it — don't rely on memory of what
    was changed.
  - Before dismissing a finding as "not applicable" on project-specific grounds (e.g.
    "this data never leaves a private scope"), **cross-check that claim against the
    target project's own docs (AGENTS.md, CLAUDE.md, README) and known project facts**
    rather than accepting it because it sounds plausible. An external reviewer doesn't
    know this project's constraints and can be wrong in the specific way of applying
    generic best practice where it doesn't fit — but that cuts both ways: don't wave
    off a finding on an unverified assumption either.

## 8. Communication

Announce the review in a single sentence when starting, and another when applying
findings or surfacing results to the user. Don't dump the full review verbatim unless
asked.
