# TODO

Improvements considered and deliberately deferred, with the trigger that would make
each worth doing. Check this before redesigning something it covers; add to it when
deferring a non-trivial idea rather than doing it half-way now.

## Copilot CLI sandbox: known limitations, accepted as-is for now

`run-copilot-review.sh` passes `--experimental --sandbox` so that, on top of
`--deny-tool write`, Copilot CLI's OS-level command sandbox also gets a chance to
catch shell-based writes (`git commit`, `rm`, etc.) that `--deny-tool write` alone
doesn't cover. Investigated thoroughly; landed on using it anyway, with two
accepted limitations rather than a deeper fix:

1. **No custom policy is configured**, so sandboxing runs under Copilot CLI's
   default "sensible starting policy" — which grants the current working directory
   (i.e. the target repo being reviewed) **read-write**, not read-only
   (`addCurrentWorkingDirectory: true` by default). A real fix would need
   `addCurrentWorkingDirectory: false` plus a `userPolicy.filesystem.readonlyPaths`
   entry pointed at the target repo, `allowDevToolAccess: false`, and a host-support
   check (macOS `sandbox-exec`, Linux needs `bwrap` 0.5.0+, Windows needs Windows 11).
   **This can't be done per-invocation without side effects**: sandbox policy only
   lives in Copilot CLI's global `~/.copilot/settings.json` — confirmed (via
   `github/copilot-cli`'s changelog.md) that repo-level settings
   (`.github/copilot/settings.json` / `.github/copilot/settings.local.json`) only
   let a trusted repo pin the model/effort-level/context-tier and extend the
   URL/MCP/skill deny lists; `sandbox` and `experimental` are not among the
   repo-overridable keys, confirmed empirically (a settings.local.json with
   `experimental: true` had no effect, with or without `--add-dir`).
2. **`--experimental` permanently persists `"experimental": true` into the user's
   global `~/.copilot/settings.json`**, confirmed by direct A/B test (removing the
   key, running without the flag → key doesn't reappear; running with the flag →
   key reappears every time). `--sandbox`/`--no-sandbox` themselves are session-only
   and don't persist, but the sandbox feature requires experimental mode, and there's
   no way to turn experimental mode on without it persisting — so this one is
   unavoidable as long as `--sandbox` is used at all.

Accepted because: (1) is a real gap but not a regression — `--deny-tool write` was
already the only protection before, so `--sandbox` with default policy is a
non-negative addition (it does shrink blast radius outside cwd/PATH/temp/profile,
just not within the target repo itself). (2) is a one-time, low-stakes global
toggle (gates experimental CLI features, not filesystem/network access) — a real
but minor cost, not worth the complexity below to avoid.

Trigger to revisit: if the `--experimental` persistence or the default-policy gap
actually causes a problem in practice, not just in theory.

If this trade-off ever looks wrong, dropping `--experimental --sandbox` from
`run-copilot-review.sh` reverts cleanly to the pre-sandbox behavior (`--deny-tool
write` only) — it's an isolated addition, not load-bearing for anything else in
this script.

## Scratch location for prompt files: resolved as a menu, not a single fixed path

Both scripts now take the review prompt as a file path (`<prompt-file>`) instead of
stdin/a heredoc — confirmed empirically that a heredoc whose body differs every
invocation can never be covered by a single Bash permission allow-rule (tried both
a `*`-suffixed and an exact-match rule; the confirmation prompt still appeared every
time), whereas a fixed prompt-file path keeps the invoked command text constant,
which a permission rule *can* match.

Originally planned to pre-register one fixed scratch directory (e.g.
`~/.cache/external-review/`) via a `Write(<dir>/**)` permission rule or
`permissions.additionalDirectories`, set up once by a future `setup` skill. Dropped
that plan after empirically confirming **Write permission grants for paths outside
the current project are session-scoped only and never persist to any settings
file** — tested across `.claude/settings.local.json` (hand-written `Write(...)`
rules, both `//tmp/...` and the symlink-resolved `//private/tmp/...` forms),
global `~/.claude/settings.json`, and `~/.claude.json`'s per-project `allowedTools`;
none of them changed after approving via "allow all edits in `<dir>` during this
session," including across a full session restart (which still required a fresh
confirmation). So there is no way to make an out-of-project scratch directory
permission-free forever — only "at most one confirmation per session" is
achievable, no matter how it's registered.

Given that, SKILL.md now documents three options and lets the calling agent pick
per-environment, instead of standardizing on one:
1. The target repo's own established gitignored scratch convention if it has one
   (e.g. `tmp/`) — zero friction, zero contamination risk.
2. Anywhere in the repo — same zero friction; neither script deletes
   `<prompt-file>` (it belongs to the caller, not the script), so it could in
   principle be mistaken for part of the diff -- both scripts instead tell the
   reviewer the exact path used to pass it the prompt, so it can recognize and
   disregard that file itself.
3. Outside the repo (e.g. `/tmp/`) — zero repo contact, at the cost of the
   one-confirmation-per-session floor described above.

No further action needed here unless `skills/setup/SKILL.md` later grows a way to
smooth over option 3's per-session confirmation somehow (no known mechanism to do
so today).

Registering a Bash allow-rule for the scripts themselves (so review invocations
don't prompt every time) is no longer a TODO — `skills/setup/SKILL.md` step 3 does
this now, in global `~/.claude/settings.json` (confirmed working during dogfooding:
a rule shaped like `Bash(<path>/scripts/run-codex-review.sh *)` does suppress the
prompt once registered and picked up).

## Consider `codex app-server` instead of `codex exec`, if it ever gets easy to use

`run-codex-review.sh` uses `codex exec --sandbox read-only --ephemeral` — a stable,
simple, one-shot non-interactive invocation that matches this script's needs exactly.
Codex CLI also has a `codex app-server` command: an `[experimental]` long-running
daemon that speaks a structured RPC protocol (stdio/unix socket/websocket), meant for
building custom integrations (e.g. IDE extensions; `openai-codex`'s own Claude Code
plugin ships a whole Node.js client for it — `scripts/app-server-broker.mjs`,
`scripts/lib/app-server.mjs`). Not worth adopting today: it'd require this repo to
implement or depend on an RPC client just to run one review and read back one
response, for no clear benefit over `exec`, and it's explicitly less stable
(`[experimental]`) than the command already in use.

Trigger to revisit: if a lightweight, low-dependency way to talk to `app-server`
becomes available (e.g. a small bundled client, or `codex` itself grows a simpler
one-shot mode that's backed by it) such that switching wouldn't mean reimplementing
an RPC client from scratch in this repo's own bash scripts.

## Consider Claude Code as a candidate reviewer, when the underlying model differs

The independence this skill actually cares about (SKILL.md's "If both fail" rule:
don't substitute a same-vendor/model-family subagent for the agent that implemented
the change) is about the **underlying model**, not which CLI binary happens to be
running. "Codex CLI + Copilot CLI, never Claude Code" is just today's proxy for that,
and it only works because the primary use case today is Claude Code itself
implementing changes — so excluding Claude Code as a reviewer happens to also exclude
the implementer's model family.

That proxy already breaks in a case that exists today: **Copilot CLI itself can run
on Claude models** (`--model claude-sonnet-5` and other Claude variants are in its
supported model list, per `copilot help config`). If Claude Code is the implementer
and a Copilot CLI fallback happens to be configured with a Claude model, that
fallback isn't actually an independent reviewer, even though it's a different CLI
program — the same model family reviewing itself under a different CLI's name.

And the reverse case matters for portability too: this skill is meant to be portable
across the whole Agent Skills ecosystem (see CLAUDE.md's conventions on
`${CLAUDE_PLUGIN_ROOT}`) — including being installed for **Codex CLI or Copilot CLI
as the implementing agent** (e.g. via `.agents/skills/`). In that case, Claude Code
(via `claude -p` non-interactively) would be a genuinely independent, different-model
reviewer, not a self-review — worth adding as a third candidate.

Not designed yet because both directions need the same missing piece: a way to check
*which model* is actually implementing versus which model a candidate reviewer would
run on (e.g. reading Copilot CLI's configured `--model`/`model` setting before
trusting it as independent), rather than hardcoding "not Claude Code" as a stand-in
for "not the implementer's model family."

Trigger to revisit: when this skill gets used with a non-Claude-Code implementing
agent (making Claude Code's exclusion from the reviewer roster start to matter), or
when a Copilot CLI fallback configured with a Claude model is observed reviewing a
Claude Code implementer's own change.
