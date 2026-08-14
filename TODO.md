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
toggle (gates experimental CLI features, not filesystem/network access) — not
nothing, but not worth the complexity below to avoid.

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
2. Anywhere in the repo — same zero friction; both scripts now delete
   `<prompt-file>` themselves right after reading it, before invoking the reviewer,
   so nobody has to remember cleanup.
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
