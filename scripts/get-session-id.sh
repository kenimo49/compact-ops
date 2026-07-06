#!/usr/bin/env bash
# Detect the current Claude Code session id from inside a session.
# Claude Code stores transcripts under ~/.claude/projects/<munged-cwd>/<session-id>.jsonl
# where the munged cwd replaces "/" and "." with "-". The most recently
# modified transcript for the current project is the running session.
# Bundled with the plugin so the /compact-ops skill has no external dependency
# (compact-plus requires the author's private ~/.claude/scripts/get-session-id.sh).

set -euo pipefail

PROJECT_DIR="$HOME/.claude/projects/$(pwd | sed 's|[/.]|-|g')"
[[ -d "$PROJECT_DIR" ]] || { echo "session id not found: no project dir $PROJECT_DIR" >&2; exit 1; }

LATEST=$(ls -1t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -n 1)
[[ -n "$LATEST" ]] || { echo "session id not found: no transcript in $PROJECT_DIR" >&2; exit 1; }

basename "$LATEST" .jsonl
