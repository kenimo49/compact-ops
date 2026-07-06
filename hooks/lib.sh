#!/usr/bin/env bash
# Shared helpers for compact-ops hooks. Sourced, not executed.
# All state lives under ~/.claude/compact-ops/ so it survives reboots
# (compact-plus keeps state in $TMPDIR, which is lost on restart).

COMPACT_OPS_HOME="${COMPACT_OPS_HOME:-$HOME/.claude/compact-ops}"
STATE_ROOT="$COMPACT_OPS_HOME/state"
BACKUP_ROOT="$COMPACT_OPS_HOME/backups"
# One-shot markers are ephemeral by design; TMPDIR is fine for them.
MARKER_ROOT="${TMPDIR:-/tmp}/claude-compact-ops"

cwd_hash() {
  printf '%s' "$1" | md5sum | cut -c1-12
}

state_dir_for_cwd() {
  printf '%s/%s' "$STATE_ROOT" "$(cwd_hash "$1")"
}

state_file_for() {
  # $1 = cwd, $2 = session_id
  printf '%s/%s.md' "$(state_dir_for_cwd "$1")" "$2"
}

read_hook_field() {
  # $1 = json input, $2 = jq filter
  printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null || true
}

emit_additional_context() {
  # $1 = hook event name, $2 = context text
  jq -n --arg event "$1" --arg ctx "$2" '{
    hookSpecificOutput: {
      hookEventName: $event,
      additionalContext: $ctx
    }
  }'
}

prune_old_files() {
  # $1 = dir, $2 = retention days
  [[ -d "$1" ]] || return 0
  find "$1" -type f -mtime +"$2" -delete 2>/dev/null || true
}
