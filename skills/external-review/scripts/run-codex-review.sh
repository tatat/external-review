#!/bin/bash
# Runs a Codex CLI review with the prompt read from a file, printing just the
# final message and exiting with codex's own exit code.
#
# Usage:
#   run-codex-review.sh <prompt-file> [model]
#
# The prompt is read from <prompt-file>, not stdin/a heredoc -- a heredoc's body
# differs on every invocation, which means it can never be covered by a single
# Bash permission allow-rule (confirmed empirically: neither a wildcard nor an
# exact-match rule suppresses the confirmation prompt for a command whose
# heredoc content varies). A fixed prompt-file path keeps the invoked command
# text itself constant across invocations, which a permission rule CAN match.
# <prompt-file> is only ever read by this script, never written to or deleted --
# it belongs to the caller, and this script has no business managing its
# lifecycle. If the caller wrote it inside the target repo's own working tree, it
# may still be sitting there (e.g. as an untracked file) by the time codex exec
# investigates "pending changes"; instead of removing it, this script tells codex
# exactly which path was used to pass it the prompt (see PROMPT_FILE_NOTE below)
# so it can recognize and disregard that file if it encounters it, rather than
# mistaking it for part of the diff.
# If [model] is omitted, codex's own configured default model is used.
#
# Two fixed preambles, no-recursion-preamble.txt and default-review-focus.txt (both
# next to this script), are read and prepended to whatever prompt is in
# <prompt-file>:
# - no-recursion-preamble.txt tells Codex it IS the review step and must not act on
#   the target repo's own AGENTS.md/CLAUDE.md/skill instructions. Without it, Codex
#   -- an agentic tool with read access to the target repo -- may read those and try
#   to recursively invoke an external review of its own review: it has been observed
#   calling both run-codex-review.sh and run-copilot-review.sh on itself, then
#   failing because its own `--sandbox read-only --ephemeral` run has no writable
#   temp dir and no network access.
# - default-review-focus.txt tells Codex to defer to the target repo's own
#   documented review priorities if it has any, and otherwise flag a fixed list of
#   default concerns, so a default review policy always applies even when the
#   caller's own prompt doesn't mention one.
# Both are read from disk by this script (not left for Codex to go read itself) so
# neither depends on Codex's sandboxed read access reaching outside the target
# repo's working tree -- a real risk for Copilot's default sandbox policy, see
# TODO.md, and this script has no way to know it's safe for Codex too.
#
# `codex exec`'s own verbose transcript (every tool call it makes) is redirected to
# $LOG rather than printed here, so normal output is just the clean final report in
# $OUT. Neither file is deleted -- if something goes wrong, read $LOG for the full
# trace; on success there's normally no need to.
#
# Set EXTERNAL_REVIEW_CODEX_LOG_DIR to control where $OUT/$LOG are created instead
# of the system default temp directory (mirrors EXTERNAL_REVIEW_COPILOT_LOG_DIR in
# run-copilot-review.sh).
set -uo pipefail

if [ -n "${EXTERNAL_REVIEW_CODEX_LOG_DIR:-}" ]; then
  mkdir -p "$EXTERNAL_REVIEW_CODEX_LOG_DIR"
  MKTEMP_DIR_ARGS=(-p "$EXTERNAL_REVIEW_CODEX_LOG_DIR")
else
  MKTEMP_DIR_ARGS=()
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! NO_RECURSION_PREAMBLE="$(cat "$SCRIPT_DIR/no-recursion-preamble.txt")"; then
  echo "run-codex-review.sh: couldn't read $SCRIPT_DIR/no-recursion-preamble.txt" >&2
  exit 1
fi
if ! DEFAULT_FOCUS_PREAMBLE="$(cat "$SCRIPT_DIR/default-review-focus.txt")"; then
  echo "run-codex-review.sh: couldn't read $SCRIPT_DIR/default-review-focus.txt" >&2
  exit 1
fi

PROMPT_FILE="${1:?usage: run-codex-review.sh <prompt-file> [model]}"
MODEL="${2:-}"
if ! PROMPT_CONTENT="$(cat "$PROMPT_FILE")"; then
  echo "run-codex-review.sh: couldn't read prompt file: $PROMPT_FILE" >&2
  exit 1
fi
OUT="$(mktemp ${MKTEMP_DIR_ARGS[@]+"${MKTEMP_DIR_ARGS[@]}"})"
LOG="$(mktemp ${MKTEMP_DIR_ARGS[@]+"${MKTEMP_DIR_ARGS[@]}"})"
PROMPT_FILE_NOTE="Note: $PROMPT_FILE was used to pass you this prompt as a temporary file. If it's still present in the working tree, it is tooling plumbing, not part of the change being reviewed -- disregard it."
FULL_PROMPT="$NO_RECURSION_PREAMBLE"$'\n\n---\n\n'"$DEFAULT_FOCUS_PREAMBLE"$'\n\n---\n\n'"$PROMPT_FILE_NOTE"$'\n\n---\n\n'"$PROMPT_CONTENT"

if [ -n "$MODEL" ]; then
  printf '%s' "$FULL_PROMPT" | codex exec --sandbox read-only --ephemeral --model "$MODEL" -o "$OUT" - > "$LOG" 2>&1
else
  printf '%s' "$FULL_PROMPT" | codex exec --sandbox read-only --ephemeral -o "$OUT" - > "$LOG" 2>&1
fi
CODEX_EXIT=$?

echo "Full trace: $LOG" >&2

cat "$OUT"
exit "$CODEX_EXIT"
