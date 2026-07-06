#!/usr/bin/env bash
# UserPromptSubmit hook: self-contained context-usage warning.
#
# compact-plus delegates threshold detection to a statusline script that lives
# in the author's separate dotfiles repo, so the warning never fires on a
# plugin-only install. compact-ops computes usage directly from the transcript:
# the newest main-chain assistant message carries message.usage, and
# input + cache_read + cache_creation tokens ≈ current context footprint.
#
# When usage >= COMPACT_OPS_WARN_THRESHOLD (default 60%), inject a one-shot
# reminder plus a 3-line state recitation so the agent keeps the big picture
# during the turns between the warning and the actual /compact.
# Cooldown resets in postcompact-reset.sh.
#
# overhead per turn: tail + jq over the last transcript lines.
# fail-open (always exit 0)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

COMPACT_OPS_WARN_THRESHOLD="${COMPACT_OPS_WARN_THRESHOLD:-60}"
COMPACT_OPS_CONTEXT_WINDOW="${COMPACT_OPS_CONTEXT_WINDOW:-200000}"

INPUT=$(cat)
SESSION_ID=$(read_hook_field "$INPUT" '.session_id')
TRANSCRIPT_PATH=$(read_hook_field "$INPUT" '.transcript_path')
CWD=$(read_hook_field "$INPUT" '.cwd')

[[ -n "$SESSION_ID" ]] || exit 0
[[ -f "$TRANSCRIPT_PATH" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# One-shot: stay silent until the cooldown is cleared by PostCompact.
WARNED_MARKER="$MARKER_ROOT/warned/$SESSION_ID"
[[ -f "$WARNED_MARKER" ]] && exit 0

# Newest main-chain assistant usage. fromjson? skips malformed lines instead
# of aborting the stream; sidechain (subagent) usage is not the main context.
TOKENS=$(tail -n 400 "$TRANSCRIPT_PATH" 2>/dev/null | jq -rR '
  fromjson?
  | select(.type == "assistant" and ((.isSidechain // false) | not))
  | .message.usage? // empty
  | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)
' 2>/dev/null | tail -n 1)

[[ "$TOKENS" =~ ^[0-9]+$ ]] || exit 0
[[ "$COMPACT_OPS_CONTEXT_WINDOW" =~ ^[0-9]+$ && "$COMPACT_OPS_CONTEXT_WINDOW" -gt 0 ]] || exit 0

PCT=$((TOKENS * 100 / COMPACT_OPS_CONTEXT_WINDOW))
[[ "$PCT" -ge "$COMPACT_OPS_WARN_THRESHOLD" ]] || exit 0

mkdir -p "$MARKER_ROOT/warned" 2>/dev/null || true
printf '%s\n' "$(date +%s)" > "$WARNED_MARKER" 2>/dev/null || true

section_first_line() {
  awk -v heading="$1" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit }
    in_section {
      line = $0
      sub(/^[[:space:]-]+/, "", line)
      if (line != "") { print line; exit }
    }
  ' "$2" 2>/dev/null
}

section_last_line() {
  awk -v heading="$1" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit }
    in_section {
      line = $0
      sub(/^[[:space:]-]+/, "", line)
      if (line != "") { last = line }
    }
    END { if (last != "") print last }
  ' "$2" 2>/dev/null
}

STATE_FILE=$(state_file_for "$CWD" "$SESSION_ID")

CTX="[COMPACT WARNING] Context usage reached ${PCT}% (${TOKENS} / ${COMPACT_OPS_CONTEXT_WINDOW} tokens)."
if [[ -f "$STATE_FILE" ]]; then
  ACTIVE_PLAN=$(section_first_line "## Active Plan" "$STATE_FILE")
  CURRENT_PHASE=$(section_first_line "## Current Phase" "$STATE_FILE")
  SESSION_DECISION=$(section_last_line "## Session Decisions" "$STATE_FILE")
  CTX+=$'\n'"State recitation:"
  CTX+=$'\n'"- Active Plan: ${ACTIVE_PLAN:-Not verified}"
  CTX+=$'\n'"- Current Phase: ${CURRENT_PHASE:-Not verified}"
  CTX+=$'\n'"- Recent Session Decision: ${SESSION_DECISION:-Not verified}"
fi
CTX+=$'\n'"- At a natural work boundary, tell the user they can run \`/compact\` as-is; the PreCompact hook saves structured state automatically."
CTX+=$'\n'"- Do not shrink scope or rush the task because of this warning; state capture handles continuity."

emit_additional_context "UserPromptSubmit" "$CTX"
exit 0
