#!/usr/bin/env bash
# PostCompact hook: reset the context-usage warning cooldown so the warn hook
# can fire again as the fresh context fills back up.
# Recovery injection itself happens in sessionstart-recovery.sh (matcher: compact).
# fail-open (always exit 0)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

INPUT=$(cat)
SESSION_ID=$(read_hook_field "$INPUT" '.session_id')
[[ -n "$SESSION_ID" ]] || exit 0

rm -f "$MARKER_ROOT/warned/$SESSION_ID" 2>/dev/null || true

exit 0
