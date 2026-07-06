#!/usr/bin/env bash
# SessionStart hook (matcher: compact|resume): inject recovery guidance.
#
# - source == "compact": the fresh post-compaction context. Point the agent at
#   the state file written by the PreCompact hook (compact-plus does this via a
#   PostCompact marker consumed on the next UserPromptSubmit; SessionStart's
#   compact matcher makes that indirection unnecessary).
# - source == "resume": cross-session recovery. Prefer this session's own state
#   file; otherwise fall back to the newest state file for the same project cwd
#   (72h freshness cap). This is what /tmp-based state can never do after a
#   reboot.
#
# fail-open (always exit 0)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
COMPACT_OPS_HOOK="sessionstart-recovery"

COMPACT_OPS_RESUME_MAX_AGE_HOURS="${COMPACT_OPS_RESUME_MAX_AGE_HOURS:-72}"

INPUT=$(cat)
SESSION_ID=$(read_hook_field "$INPUT" '.session_id')
SOURCE=$(read_hook_field "$INPUT" '.source')
CWD=$(read_hook_field "$INPUT" '.cwd')

[[ -n "$SESSION_ID" ]] || exit 0
valid_session_id "$SESSION_ID" || { debug_log "rejected session_id: $SESSION_ID"; exit 0; }
case "$SOURCE" in
  compact|resume) ;;
  *) exit 0 ;;
esac

STATE_DIR=$(state_dir_for_cwd "$CWD")
STATE_FILE="$STATE_DIR/$SESSION_ID.md"
STATE_NOTE=""

if [[ ! -f "$STATE_FILE" && "$SOURCE" == "resume" ]]; then
  # Fall back to the newest fresh VALID state file from the same project.
  # `-exec ls -1t {} +` sorts by mtime without GNU-only `xargs -r` (BSD/macOS
  # safe); the header grep skips corrupted or unrelated markdown files.
  CANDIDATE=""
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    grep -q '^# Compact Prep State' "$f" 2>/dev/null || continue
    CANDIDATE="$f"
    break
  done < <(find "$STATE_DIR" -maxdepth 1 -type f -name '*.md' \
      -mmin -"$((COMPACT_OPS_RESUME_MAX_AGE_HOURS * 60))" -exec ls -1t {} + 2>/dev/null)
  if [[ -n "$CANDIDATE" ]]; then
    STATE_FILE="$CANDIDATE"
    STATE_NOTE=" (written by a previous session in this project; verify it matches the work being resumed)"
  fi
fi

if [[ "$SOURCE" == "compact" ]]; then
  CTX="[COMPACTION RECOVERY] Context compaction occurred. Before resuming work, use the following recovery references."
else
  CTX="[RESUME RECOVERY] This session was resumed. A saved pre-compaction state file exists for this project."
fi
CTX+=$'\n'

if [[ -f "$STATE_FILE" ]]; then
  CTX+=$'\n'"- Read state file \`${STATE_FILE}\` with Read and restore the working state${STATE_NOTE}."
  CTX+=$'\n'"- Pay special attention to Session Decisions, Failed Attempts, and Recovery Notes."
  if grep -q '^## Skills Invoked' "$STATE_FILE" 2>/dev/null; then
    CTX+=$'\n'"- The state file lists previously invoked skills under \`## Skills Invoked\`. Skills are NOT active after compaction; re-invoke them via the Skill tool before relying on their instructions."
  fi
else
  if [[ "$SOURCE" == "resume" ]]; then
    # Nothing useful to inject on a plain resume with no saved state.
    exit 0
  fi
  BACKUP_FILE=$(find "$BACKUP_ROOT" -maxdepth 1 -type f \( -name "*-$SESSION_ID.jsonl" -o -name "*-$SESSION_ID.jsonl.gz" \) -print 2>/dev/null | sort -r | head -n 1)
  if [[ -n "$BACKUP_FILE" ]]; then
    CTX+=$'\n'"- No state file was found. Transcript backup \`${BACKUP_FILE}\` exists; read it (gzip: decompress first) if recovery details are needed."
  fi
fi

CTX+=$'\n'"- Check the task list for current tasks."
CTX+=$'\n'"- Treat next steps from the compaction summary as hypotheses; plans, rules, and original files are the source of truth."
CTX+=$'\n'"- Original memory / rule / skill files are authoritative; compaction summaries may omit scope qualifiers."

emit_additional_context "SessionStart" "$CTX"
exit 0
