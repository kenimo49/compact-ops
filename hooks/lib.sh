#!/usr/bin/env bash
# Shared helpers for compact-ops hooks. Sourced, not executed.
# All state lives under ~/.claude/compact-ops/ so it survives reboots
# (compact-plus keeps state in $TMPDIR, which is lost on restart).

# Transcripts and state files carry conversation content (possibly secrets
# echoed by tools); keep everything we create private to the user.
umask 077

COMPACT_OPS_HOME="${COMPACT_OPS_HOME:-$HOME/.claude/compact-ops}"
STATE_ROOT="$COMPACT_OPS_HOME/state"
BACKUP_ROOT="$COMPACT_OPS_HOME/backups"
LOG_ROOT="$COMPACT_OPS_HOME/logs"
COMPACT_OPS_DEBUG="${COMPACT_OPS_DEBUG:-0}"
# One-shot markers are ephemeral by design; TMPDIR is fine for them.
MARKER_ROOT="${TMPDIR:-/tmp}/claude-compact-ops"

cwd_hash() {
  # GNU md5sum, macOS md5, then shasum — same 12-char prefix on Linux either way,
  # so existing state dirs keep working.
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$1" | md5sum | cut -c1-12
  elif command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 | awk '{print $NF}' | cut -c1-12
  else
    printf '%s' "$1" | shasum | cut -c1-12
  fi
}

state_dir_for_cwd() {
  printf '%s/%s' "$STATE_ROOT" "$(cwd_hash "$1")"
}

state_file_for() {
  # $1 = cwd, $2 = session_id
  printf '%s/%s.md' "$(state_dir_for_cwd "$1")" "$2"
}

valid_session_id() {
  # session_id becomes part of file names, globs, and rm targets; never trust
  # hook input blindly. Claude session ids are UUID-shaped, so allowlist that.
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]]
}

debug_log() {
  # Fail-open must not mean undiagnosable: with COMPACT_OPS_DEBUG=1 every
  # swallowed failure leaves one line here.
  [[ "$COMPACT_OPS_DEBUG" == "1" ]] || return 0
  mkdir -p "$LOG_ROOT" 2>/dev/null || return 0
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${COMPACT_OPS_HOOK:-hook}" "$*" \
    >> "$LOG_ROOT/compact-ops.log" 2>/dev/null || true
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
