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
# <prompt-file> is deleted as soon as its content is read into memory, before
# codex exec starts -- so if the caller wrote it inside the target repo's own
# working tree, it's already gone before codex investigates "pending changes"
# and can't be mistaken for part of the diff.
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
rm -f "$PROMPT_FILE"
OUT="$(mktemp ${MKTEMP_DIR_ARGS[@]+"${MKTEMP_DIR_ARGS[@]}"})"
LOG="$(mktemp ${MKTEMP_DIR_ARGS[@]+"${MKTEMP_DIR_ARGS[@]}"})"
FULL_PROMPT="$NO_RECURSION_PREAMBLE"$'\n\n---\n\n'"$DEFAULT_FOCUS_PREAMBLE"$'\n\n---\n\n'"$PROMPT_CONTENT"

if [ -n "$MODEL" ]; then
  printf '%s' "$FULL_PROMPT" | codex exec --sandbox read-only --ephemeral --model "$MODEL" -o "$OUT" - > "$LOG" 2>&1
else
  printf '%s' "$FULL_PROMPT" | codex exec --sandbox read-only --ephemeral -o "$OUT" - > "$LOG" 2>&1
fi
CODEX_EXIT=$?

echo "Full trace: $LOG" >&2

cat "$OUT"
exit "$CODEX_EXIT"
