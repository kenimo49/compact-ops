---
name: compact-ops
description: |
  Save the current Claude Code session state to the persistent compact-ops state file before running /compact.
  MANDATORY TRIGGERS: /compact-ops, compact-ops, compact ops, pre-compact state save, compaction handoff save.
  DO NOT TRIGGER: post-compact recovery, ordinary progress updates, plan creation, or casual context-usage discussion.
strict_procedure: true
argument-hint: "[recovery notes]"
allowed-tools: Bash, Read, Write, Edit, Grep
---

# compact-ops

The PreCompact hook already saves a state file automatically whenever `/compact` runs.
This skill is the manual fallback: use it when the agent should write a richer,
self-authored state file right before compaction (the agent knows nuances an
LLM summarizer can miss).

## Strict procedure profile

- Strictness: strict-procedure. The state file content and completion receipt are the deliverable.
- Hard gate: if the session id cannot be detected, do not create a guessed state file name. Stop and report that session id detection failed.
- Forcing function: fix the destination path, then read the saved file back and verify that the required headings exist.
- Completion receipt: report the state file path, main saved items, unverified items, and the instruction to run `/compact`.

## Procedure

1. Get the session id and destination path.
   - Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/get-session-id.sh"` (bundled with this plugin).
   - If it fails, stop and report that preparation is incomplete because the session id is unavailable.
2. Compute the destination:
   - `CWD_HASH=$(printf '%s' "$PWD" | md5sum | cut -c1-12)`
   - Destination: `~/.claude/compact-ops/state/${CWD_HASH}/${SESSION_ID}.md`
   - Create the directory if needed.
3. Review the task list, any active plan, and files currently being edited.
4. Write the state file with these headings in this exact order:

```markdown
# Compact Prep State
## Active Plan
## Current Phase
## TaskList Summary
## Session Decisions
## Constraints and Blockers
## Worker Topology
## Skills Invoked
## Editing Files
## Failed Attempts
## Recovery Notes
```

5. Read the state file back and verify every heading exists.
6. Tell the user: `Preparation complete. Please run /compact.`

## Content to save

- Active plan file path and current phase or step.
- In-progress task list and relevant notes.
- Decisions made during the session, user choices, and rejected alternatives with rationale.
- Constraints, blockers, and incomplete verification.
- Worker topology (subagents / panes) or `Not used`.
- Skills and slash commands invoked earlier in the session. This is an invocation record, not proof the skill is currently active.
- Files being edited and notes about unsaved or unverified work.
- Failed attempts, tool errors, and rejected approaches that should not be repeated.
- Recovery notes for the post-compaction agent: session_id, branch, key commands, validation results.
- If the user passed arguments to this skill, treat them as priority recovery notes.
