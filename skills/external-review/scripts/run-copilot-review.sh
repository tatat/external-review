#!/bin/bash
# Runs a GitHub Copilot CLI review with the prompt read from a file.
#
# Usage:
#   run-copilot-review.sh <prompt-file> [model]
#
# The prompt is read from <prompt-file>, not stdin/a heredoc -- see
# run-codex-review.sh's comment for why: a heredoc's varying body can't be
# covered by a single Bash permission allow-rule (confirmed empirically), while
# a fixed prompt-file path keeps the invoked command text constant.
# <prompt-file> is only ever read by this script, never written to or deleted --
# it belongs to the caller, and this script has no business managing its
# lifecycle. If the caller wrote it inside the target repo's own working tree, it
# may still be sitting there (e.g. as an untracked file) by the time copilot
# investigates "pending changes"; instead of removing it, this script tells
# copilot exactly which path was used to pass it the prompt (see
# PROMPT_FILE_NOTE below) so it can recognize and disregard that file if it
# encounters it, rather than mistaking it for part of the diff.
#
# Defaults to gpt-5.5 if [model] is omitted, intended to match the current Codex
# CLI default (see run-codex-review.sh -- it doesn't pin a model itself, it defers
# to whatever Codex CLI is configured to use) so both reviewers run on a
# comparable model/cost tier rather than an arbitrary pick. If Codex CLI's default
# changes, update this to match.
#
# Two fixed preambles, no-recursion-preamble.txt and default-review-focus.txt (both
# next to this script, shared with run-codex-review.sh), are read and prepended to
# whatever prompt is in <prompt-file> -- see run-codex-review.sh's comment for the
# full reasoning behind each:
# - no-recursion-preamble.txt: Copilot CLI (`--allow-all-tools`) also has read
#   access to the target repo and could otherwise try to act on that repo's own
#   AGENTS.md/CLAUDE.md or skill instructions, recursively invoking a review of its
#   own review.
# - default-review-focus.txt: tells Copilot to defer to the target repo's own
#   documented review priorities if it has any, and otherwise flag a fixed list of
#   default concerns, so a default review policy always applies even when the
#   caller's own prompt doesn't mention one.
# Both are read from disk by this script rather than left for Copilot to go read
# itself, since under Copilot's default sandbox policy (see below) reads outside
# the target repo's working tree aren't guaranteed to succeed.
#
# --experimental --sandbox turn on Copilot CLI's (experimental) OS-level command
# sandbox for this session, adding filesystem/network enforcement on top of
# --deny-tool write below (which only blocks the dedicated file-write tool, not
# shell-based writes like `git commit`/`rm`). No custom sandbox policy is
# configured, so this runs under Copilot CLI's default policy, which grants the
# target repo read-write -- a real gap, see TODO.md for why and what a full fix
# would need. Known side effect: --experimental permanently persists
# `"experimental": true` into the user's global ~/.copilot/settings.json (there's
# no way to enable the sandbox feature without this; --sandbox itself is
# session-only). Accepted as a low-stakes trade-off -- see TODO.md.
#
# Set EXTERNAL_REVIEW_COPILOT_SANDBOX=0 to skip both flags and fall back to
# --deny-tool write alone (e.g. if the --experimental persistence is unwanted,
# or bubblewrap isn't installed -- see the bwrap check below).
SANDBOX_FLAGS=()
if [ "${EXTERNAL_REVIEW_COPILOT_SANDBOX:-1}" != "0" ]; then
  SANDBOX_FLAGS=(--experimental --sandbox)
fi

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! NO_RECURSION_PREAMBLE="$(cat "$SCRIPT_DIR/no-recursion-preamble.txt")"; then
  echo "run-copilot-review.sh: couldn't read $SCRIPT_DIR/no-recursion-preamble.txt" >&2
  exit 1
fi
if ! DEFAULT_FOCUS_PREAMBLE="$(cat "$SCRIPT_DIR/default-review-focus.txt")"; then
  echo "run-copilot-review.sh: couldn't read $SCRIPT_DIR/default-review-focus.txt" >&2
  exit 1
fi

PROMPT_FILE="${1:?usage: run-copilot-review.sh <prompt-file> [model]}"
MODEL="${2:-gpt-5.5}"
if ! PROMPT_CONTENT="$(cat "$PROMPT_FILE")"; then
  echo "run-copilot-review.sh: couldn't read prompt file: $PROMPT_FILE" >&2
  exit 1
fi
PROMPT_FILE_NOTE="Note: $PROMPT_FILE was used to pass you this prompt as a temporary file. If it's still present in the working tree, it is tooling plumbing, not part of the change being reviewed -- disregard it."
FULL_PROMPT="$NO_RECURSION_PREAMBLE"$'\n\n---\n\n'"$DEFAULT_FOCUS_PREAMBLE"$'\n\n---\n\n'"$PROMPT_FILE_NOTE"$'\n\n---\n\n'"$PROMPT_CONTENT"

# On Linux, --sandbox requires a system `bwrap` (bubblewrap) binary (macOS uses
# `sandbox-exec`, Windows uses its own mechanism -- see TODO.md -- neither needs
# bwrap, so this check is Linux-only). Unlike Codex CLI, which falls back to a
# bundled bwrap of its own when the system one is missing, Copilot CLI has no such
# fallback on Linux: without bwrap it still starts, warns once, and then silently
# degrades for the rest of the session -- its shell runner becomes unusable (no
# `git status`/`git diff`/repo-wide search), while the process itself still exits
# 0. That leaves no signal a caller can act on short of parsing the reviewer's own
# prose for a caveat. Fail fast here instead, before ever invoking copilot, and let
# the caller decide -- installing bwrap or setting EXTERNAL_REVIEW_COPILOT_SANDBOX=0
# is a real tradeoff (OS-level sandbox vs. full tool access), not something this
# script should pick silently on the caller's behalf. Checked here, after the
# argument/preamble-file validation above (so a missing bwrap never masks an
# earlier, unrelated invocation error) but before LOG_DIR below (so a fail-fast
# exit doesn't leave an unused empty temp dir behind). See
# https://github.com/tatat/external-review/issues/2.
if [ "${#SANDBOX_FLAGS[@]}" -gt 0 ] && [ "$(uname -s)" = "Linux" ] && ! command -v bwrap >/dev/null 2>&1; then
  echo "run-copilot-review.sh: --experimental --sandbox requires bubblewrap (bwrap) on Linux, which isn't installed on this host." >&2
  echo "Install bubblewrap, or set EXTERNAL_REVIEW_COPILOT_SANDBOX=0 to run without the OS-level sandbox (falls back to --deny-tool write alone)." >&2
  exit 1
fi

# Copilot's own log directory, passed explicitly instead of relying on its
# built-in ~/.copilot/logs/ default -- that default is a persistent directory
# under the user's home that would otherwise accumulate a file per review
# invocation forever. Default here to a fresh, ephemeral temp dir per invocation
# instead (mirrors run-codex-review.sh's mktemp-based log), overridable via
# EXTERNAL_REVIEW_COPILOT_LOG_DIR. This also makes the "Full trace" lookup below
# always match wherever this invocation actually wrote its log. Created only
# after both input files and the bwrap check above have succeeded, so a failed
# read or a fail-fast bwrap check doesn't leave an orphaned empty temp dir behind.
LOG_DIR="${EXTERNAL_REVIEW_COPILOT_LOG_DIR:-$(mktemp -d)}"

# --deny-tool write blocks the dedicated file-write tool. Deny rules take
# precedence over --allow-all-tools. This alone doesn't cover shell-based writes
# (e.g. `git commit`, `rm`) -- SANDBOX_FLAGS above adds real OS-level enforcement
# for those when enabled, but under Copilot's default policy (no custom policy is
# configured -- see TODO.md) the target repo itself is still read-write, so even
# with sandboxing on, the no-recursion preamble's read-only instruction remains
# the main guard against shell-based writes within the repo being reviewed.
copilot ${SANDBOX_FLAGS[@]+"${SANDBOX_FLAGS[@]}"} --log-dir "$LOG_DIR" --model "$MODEL" --allow-all-tools --deny-tool write --silent -p "$FULL_PROMPT"
COPILOT_EXIT=$?

LOG="$(ls -t "$LOG_DIR"/*.log 2>/dev/null | head -1)"
if [ -n "$LOG" ]; then
  echo "Full trace: $LOG" >&2
fi

exit "$COPILOT_EXIT"
