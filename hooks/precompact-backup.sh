#!/usr/bin/env bash
# PreCompact hook: copy the transcript to persistent backup storage.
# fail-open: never block compaction.

set -euo pipefail
trap 'exit 0' ERR

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

INPUT=$(cat)
SESSION_ID=$(read_hook_field "$INPUT" '.session_id')
TRANSCRIPT_PATH=$(read_hook_field "$INPUT" '.transcript_path')

[[ -n "$SESSION_ID" ]] || exit 0
[[ -f "$TRANSCRIPT_PATH" ]] || exit 0

mkdir -p "$BACKUP_ROOT" 2>/dev/null || true
cp "$TRANSCRIPT_PATH" "$BACKUP_ROOT/$(date +%s)-$SESSION_ID.jsonl" 2>/dev/null || exit 0

# Keep at most 20 backups per session, and drop anything older than 30 days.
find "$BACKUP_ROOT" -maxdepth 1 -type f -name "*-$SESSION_ID.jsonl" -print 2>/dev/null \
  | sort -r \
  | tail -n +21 \
  | while IFS= read -r old; do
      rm -f "$old" 2>/dev/null || true
    done
prune_old_files "$BACKUP_ROOT" 30

exit 0
