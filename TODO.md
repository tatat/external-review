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

The only way to close (1) *and* avoid (2) entirely would be an isolated, disposable
`COPILOT_HOME` per invocation (`mktemp -d`, write a from-scratch `settings.json`
with the real restrictive policy above pointed at that invocation's target repo,
then `rm -rf` it after): that fully sidesteps the global-settings problem and
allows a genuinely dynamic per-repo policy, since the settings file is authored
fresh each time instead of relying on persisted global or (non-overridable)
repo-level config. Not pursued yet because the credential story is unverified —
whether Copilot CLI's stored auth (system credential store / macOS Keychain, per
`copilot login`'s own docs) is still reachable with a fresh `COPILOT_HOME`, or
whether `run-copilot-review.sh` would need to mint a token via `gh auth token` and
pass it through `GH_TOKEN`/`GITHUB_TOKEN` (documented as taking precedence over
stored credentials, explicitly recommended for headless automation).

Trigger to revisit: if the `--experimental` persistence or the default-policy gap
actually causes a problem in practice (not just in theory), or when this repo gets
a `setup` skill (modeled on tatat/zunda-presenter's `skills/setup`) and verifying
the isolated-`COPILOT_HOME` auth story becomes cheap to fold in alongside other
one-time environment checks (Codex/Copilot CLI installed + authenticated).

If this trade-off ever looks wrong, dropping `--experimental --sandbox` from
`run-copilot-review.sh` reverts cleanly to the pre-sandbox behavior (`--deny-tool
write` only) — it's an isolated addition, not load-bearing for anything else in
this script.
