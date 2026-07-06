#!/usr/bin/env bash
# PreCompact hook: create or update the compact-ops state file from the transcript.
# Derived from u-ichi/compact-plus precompact-state-summary.sh (MIT).
# Changes from upstream: persistent state under ~/.claude/compact-ops (per-cwd),
# COMPACT_OPS_* env names, Claude-only default backends (Sonnet primary /
# Haiku fallback), no external active-plan pointer dependency.
# fail-open: do not block compaction when config, LLM, or filesystem work fails.

set -euo pipefail
trap 'exit 0' ERR

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
COMPACT_OPS_HOOK="precompact-state"
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROMPT_FILE="$PLUGIN_ROOT/prompts/state-summary.md"
SQUASH_JQ="$SCRIPT_DIR/squash.jq"

COMPACT_OPS_TRANSCRIPT_MODE="${COMPACT_OPS_TRANSCRIPT_MODE:-incremental}"
COMPACT_OPS_TRANSCRIPT_HEAD_TURNS="${COMPACT_OPS_TRANSCRIPT_HEAD_TURNS:-5}"
COMPACT_OPS_TRANSCRIPT_TAIL_TURNS="${COMPACT_OPS_TRANSCRIPT_TAIL_TURNS:-25}"
COMPACT_OPS_TRANSCRIPT_HEAD_KB="${COMPACT_OPS_TRANSCRIPT_HEAD_KB:-10}"
COMPACT_OPS_TRANSCRIPT_TAIL_KB="${COMPACT_OPS_TRANSCRIPT_TAIL_KB:-40}"
COMPACT_OPS_INCREMENTAL_REFRESH="${COMPACT_OPS_INCREMENTAL_REFRESH:-10}"
COMPACT_OPS_MAX_OUTPUT_TOKENS="${COMPACT_OPS_MAX_OUTPUT_TOKENS:-4096}"
COMPACT_OPS_SQUASH_ENABLED="${COMPACT_OPS_SQUASH_ENABLED:-1}"
COMPACT_OPS_SQUASH_READ_LINES="${COMPACT_OPS_SQUASH_READ_LINES:-100}"
COMPACT_OPS_SQUASH_BASH_CHARS="${COMPACT_OPS_SQUASH_BASH_CHARS:-500}"
COMPACT_OPS_TWO_PASS="${COMPACT_OPS_TWO_PASS:-1}"

DEFAULT_PRIMARY_BACKEND='claude -p --model claude-sonnet-5 --effort medium --permission-mode dontAsk --output-format text --no-session-persistence --system-prompt "$SYSTEM_PROMPT"'
PRIMARY_CMD="${COMPACT_OPS_PRIMARY_BACKEND-$DEFAULT_PRIMARY_BACKEND}"

DEFAULT_FALLBACK_BACKEND='claude -p --model claude-haiku-4-5-20251001 --effort low --permission-mode dontAsk --output-format text --no-session-persistence --system-prompt "$SYSTEM_PROMPT"'
FALLBACK_CMD="${COMPACT_OPS_FALLBACK_BACKEND-$DEFAULT_FALLBACK_BACKEND}"

INPUT=$(cat)
SESSION_ID=$(read_hook_field "$INPUT" '.session_id')
TRANSCRIPT_PATH=$(read_hook_field "$INPUT" '.transcript_path')
TRIGGER=$(read_hook_field "$INPUT" '.trigger')
TRIGGER=${TRIGGER:-unknown}
CUSTOM_INSTRUCTIONS=$(read_hook_field "$INPUT" '.custom_instructions')
CWD=$(read_hook_field "$INPUT" '.cwd')

[[ -n "$SESSION_ID" ]] || exit 0
valid_session_id "$SESSION_ID" || { debug_log "rejected session_id: $SESSION_ID"; exit 0; }
[[ -n "$TRANSCRIPT_PATH" ]] || exit 0
[[ -f "$TRANSCRIPT_PATH" ]] || { debug_log "transcript not found: $TRANSCRIPT_PATH"; exit 0; }
[[ -f "$PROMPT_FILE" ]] || { debug_log "prompt file not found: $PROMPT_FILE"; exit 0; }
command -v jq >/dev/null 2>&1 || { debug_log "jq not found"; exit 0; }

STATE_DIR=$(state_dir_for_cwd "$CWD")
STATE_FILE="$STATE_DIR/$SESSION_ID.md"
OFFSET_FILE="$STATE_DIR/$SESSION_ID.offset"
COUNTER_FILE="$STATE_DIR/$SESSION_ID.counter"
mkdir -p "$STATE_DIR" 2>/dev/null || true
prune_old_files "$STATE_ROOT" 30

cap_bytes() {
  local kb="$1"
  local mode="$2"
  local max_bytes=$((kb * 1024))
  if [[ "$max_bytes" -le 0 ]]; then
    cat
  elif [[ "$mode" == "tail" ]]; then
    tail -c "$max_bytes"
  else
    head -c "$max_bytes"
  fi
}

process_transcript_stream() {
  # Single jq pass over the whole stream (see squash.jq). The previous
  # per-line bash loop spawned several jq processes per transcript line and
  # could burn the 180s hook timeout on large incremental diffs.
  if [[ "$COMPACT_OPS_SQUASH_ENABLED" != "1" || ! -f "$SQUASH_JQ" ]]; then
    cat
    return
  fi
  jq -rR \
    --argjson read_lines "$COMPACT_OPS_SQUASH_READ_LINES" \
    --argjson bash_chars "$COMPACT_OPS_SQUASH_BASH_CHARS" \
    -f "$SQUASH_JQ" 2>/dev/null || cat
}

semantic_head_tail() {
  local path="$1"
  local processed head_part tail_part
  processed=$(mktemp "${TMPDIR:-/tmp}/compact-ops-transcript.XXXXXX")
  process_transcript_stream < "$path" > "$processed"
  head_part=$(head -n "$COMPACT_OPS_TRANSCRIPT_HEAD_TURNS" "$processed" | cap_bytes "$COMPACT_OPS_TRANSCRIPT_HEAD_KB" head)
  tail_part=$(tail -n "$COMPACT_OPS_TRANSCRIPT_TAIL_TURNS" "$processed" | cap_bytes "$COMPACT_OPS_TRANSCRIPT_TAIL_KB" tail)
  rm -f "$processed" 2>/dev/null || true
  printf 'Transcript head (%s turns max):\n%s\n\nTranscript tail (%s turns max):\n%s\n' \
    "$COMPACT_OPS_TRANSCRIPT_HEAD_TURNS" "$head_part" "$COMPACT_OPS_TRANSCRIPT_TAIL_TURNS" "$tail_part"
}

semantic_tail() {
  local path="$1"
  local processed
  processed=$(mktemp "${TMPDIR:-/tmp}/compact-ops-transcript.XXXXXX")
  process_transcript_stream < "$path" > "$processed"
  tail -n "$COMPACT_OPS_TRANSCRIPT_TAIL_TURNS" "$processed" | cap_bytes "$COMPACT_OPS_TRANSCRIPT_TAIL_KB" tail
  rm -f "$processed" 2>/dev/null || true
}

transcript_from_offset() {
  local path="$1"
  local offset="$2"
  local size
  size=$(wc -c < "$path" | tr -d ' ')
  if [[ "$offset" -lt 0 || "$offset" -gt "$size" ]]; then
    return 1
  fi
  if [[ "$offset" -eq "$size" ]]; then
    printf '(no new transcript events since the previous compact)\n'
  else
    tail -c +"$((offset + 1))" "$path" | process_transcript_stream | cap_bytes "$COMPACT_OPS_TRANSCRIPT_TAIL_KB" tail
  fi
}

state_is_valid() {
  [[ -f "$STATE_FILE" ]] && grep -q '^# Compact Prep State' "$STATE_FILE" 2>/dev/null
}

offset_is_valid() {
  [[ -f "$OFFSET_FILE" ]] && grep -Eq '^[0-9]+$' "$OFFSET_FILE"
}

next_counter() {
  local value=0
  if [[ -f "$COUNTER_FILE" ]] && grep -Eq '^[0-9]+$' "$COUNTER_FILE"; then
    value=$(cat "$COUNTER_FILE")
  fi
  printf '%s' "$((value + 1))"
}

collect_skills_invoked() {
  local skills commands combined

  skills=$(
    jq -r '
      .message.content[]?
      | select(.type == "tool_use" and .name == "Skill")
      | .input.skill // empty
    ' "$TRANSCRIPT_PATH" 2>/dev/null || true
  )

  commands=$(
    jq -r '
      select(.type == "user")
      | .message.content? // .content? // empty
      | if type == "string" then .
        else (.[]? | .text? // empty)
        end
    ' "$TRANSCRIPT_PATH" 2>/dev/null \
      | grep -oE '<command-name>[^<]+</command-name>' \
      | sed -E 's|</?command-name>||g' \
      | grep -E '^/' || true
  )

  combined=$(printf '%s\n%s\n' "$skills" "$commands" | awk 'NF' | sort -u)
  if [[ -n "$combined" ]]; then
    printf '%s\n' "$combined"
  else
    printf '(none)\n'
  fi
}

build_user_prompt() {
  local mode="$1"
  local events="$2"

  printf 'session_id: %s\n' "$SESSION_ID"
  printf 'trigger: %s\n' "$TRIGGER"
  printf 'cwd: %s\n' "$CWD"
  printf 'transcript_path: %s\n' "$TRANSCRIPT_PATH"
  printf 'state_file: %s\n' "$STATE_FILE"
  printf 'mode: %s\n' "$mode"
  printf 'two_pass_enabled: %s\n' "$COMPACT_OPS_TWO_PASS"
  if [[ "$COMPACT_OPS_TWO_PASS" != "1" ]]; then
    printf 'Two-pass override: the internal two-pass process is DISABLED for this run. Draft once and output the final state directly, skipping the self-critique step.\n'
  fi
  printf '\nExisting state (from previous /compact):\n'
  if state_is_valid && [[ "$mode" == "incremental" ]]; then
    cat "$STATE_FILE"
  else
    printf '(none)\n'
  fi
  printf '\n\nCustom instructions from user:\n%s\n' "${CUSTOM_INSTRUCTIONS:-"(none)"}"
  printf '\nSkills and commands invoked this session:\n%s\n' "$SKILLS_INVOKED_LIST"
  printf '\nNew events since last compact:\n%s\n' "$events"
  printf '\nTask: Generate or update the state summary using ADD, UPDATE, and PRESERVE operations.\n'
  printf 'Priority: honor user custom_instructions if provided.\n'
}

validate_state_output() {
  # Guard against overwriting a good state file with a malformed one:
  # require the exact title line and all 10 headings.
  local out="$1" h
  [[ "$(printf '%s\n' "$out" | head -n 1)" == "# Compact Prep State" ]] || return 1
  for h in "## Active Plan" "## Current Phase" "## TaskList Summary" \
           "## Session Decisions" "## Constraints and Blockers" "## Worker Topology" \
           "## Skills Invoked" "## Editing Files" "## Failed Attempts" "## Recovery Notes"; do
    printf '%s\n' "$out" | grep -qxF "$h" || { debug_log "state output missing heading: $h"; return 1; }
  done
}

run_backend_if_set() {
  local cmd="$1"
  local user_prompt="$2"
  local output stderr_target

  [[ -n "$cmd" ]] || return 1

  stderr_target=/dev/null
  if [[ "$COMPACT_OPS_DEBUG" == "1" ]]; then
    mkdir -p "$LOG_ROOT" 2>/dev/null || true
    stderr_target="$LOG_ROOT/backend-stderr.log"
  fi

  if output=$(SYSTEM_PROMPT="$SYSTEM_PROMPT" SESSION_ID="$SESSION_ID" TRANSCRIPT_PATH="$TRANSCRIPT_PATH" MAX_OUTPUT_TOKENS="$COMPACT_OPS_MAX_OUTPUT_TOKENS" bash -c "$cmd" <<< "$user_prompt" 2>>"$stderr_target"); then
    if validate_state_output "$output"; then
      printf '%s\n' "$output"
      return 0
    fi
    debug_log "backend output failed validation (cmd: ${cmd:0:60}...)"
  else
    debug_log "backend command failed (cmd: ${cmd:0:60}...)"
  fi
  return 1
}

run_backends() {
  local user_prompt="$1"
  if run_backend_if_set "$PRIMARY_CMD" "$user_prompt"; then
    return 0
  fi
  if run_backend_if_set "$FALLBACK_CMD" "$user_prompt"; then
    return 0
  fi
  return 1
}

TRANSCRIPT_SIZE=$(wc -c < "$TRANSCRIPT_PATH" | tr -d ' ')
CALL_COUNT=$(next_counter)
MODE="$COMPACT_OPS_TRANSCRIPT_MODE"
EVENTS=""
OFFSET=0

case "$MODE" in
  tail)
    EVENTS=$(semantic_tail "$TRANSCRIPT_PATH")
    MODE="tail"
    ;;
  head-tail)
    EVENTS=$(semantic_head_tail "$TRANSCRIPT_PATH")
    MODE="head-tail"
    ;;
  incremental|*)
    MODE="incremental"
    if ! state_is_valid; then
      EVENTS=$(semantic_head_tail "$TRANSCRIPT_PATH")
      MODE="initial"
    elif [[ "$COMPACT_OPS_INCREMENTAL_REFRESH" =~ ^[0-9]+$ ]] && [[ "$COMPACT_OPS_INCREMENTAL_REFRESH" -gt 0 ]] && [[ $((CALL_COUNT % COMPACT_OPS_INCREMENTAL_REFRESH)) -eq 0 ]]; then
      EVENTS=$(semantic_head_tail "$TRANSCRIPT_PATH")
      MODE="refresh"
    elif ! offset_is_valid; then
      EVENTS=$(semantic_head_tail "$TRANSCRIPT_PATH")
      MODE="initial"
    else
      OFFSET=$(cat "$OFFSET_FILE")
      if ! EVENTS=$(transcript_from_offset "$TRANSCRIPT_PATH" "$OFFSET"); then
        EVENTS=$(semantic_head_tail "$TRANSCRIPT_PATH")
        MODE="initial"
      fi
    fi
    ;;
esac

SYSTEM_PROMPT=$(cat "$PROMPT_FILE")
SKILLS_INVOKED_LIST=$(collect_skills_invoked)
USER_PROMPT=$(build_user_prompt "$MODE" "$EVENTS")

OUTPUT=$(run_backends "$USER_PROMPT" || true)
[[ -n "$OUTPUT" ]] || { debug_log "all backends failed; keeping previous state file"; exit 0; }

TMP_FILE=$(mktemp "$STATE_DIR/.state.XXXXXX")
printf '%s\n' "$OUTPUT" > "$TMP_FILE"
mv "$TMP_FILE" "$STATE_FILE" 2>/dev/null || true
printf '%s\n' "$TRANSCRIPT_SIZE" > "$OFFSET_FILE" 2>/dev/null || true
printf '%s\n' "$CALL_COUNT" > "$COUNTER_FILE" 2>/dev/null || true

exit 0
