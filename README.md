# compact-ops

[日本語 README](./README.ja.md)

A transparent Claude Code plugin that keeps sessions coherent across context compaction: structured state capture before `/compact`, recovery injection right after compaction and on `--resume`, plus a self-contained context-usage warning. It never touches the compaction algorithm itself — official hooks only.

Derived from [u-ichi/compact-plus](https://github.com/u-ichi/compact-plus) (MIT) with three changes:

1. **Self-contained warnings** — compact-plus relies on a statusline script from the author's separate dotfiles repo for its context-usage warning, so it never fires on a plugin-only install. compact-ops computes usage directly from the transcript's latest assistant `message.usage` inside a UserPromptSubmit hook.
2. **Persistent state** — state files live under `~/.claude/compact-ops/` (organized per project cwd, 30-day retention) instead of `$TMPDIR`, so they survive reboots.
3. **Cross-session recovery** — a SessionStart hook injects recovery guidance on `--resume` as well as right after compaction (via the `compact` matcher, replacing the PostCompact-marker → UserPromptSubmit indirection), with a fallback to the newest state file from the same project (72h freshness cap).

Also: the manual `/compact-ops` skill's session-id detection script is bundled with the plugin, and the default LLM backends are Claude-only (Sonnet primary, Haiku fallback).

## Install

```bash
git clone https://github.com/kenimo49/compact-ops.git
claude plugin marketplace add /path/to/compact-ops --scope user
claude plugin install compact-ops@compact-ops-local
```

Requires Claude Code v2.x, `jq`, and the `claude` CLI as the LLM backend.

After installing, just run `/compact` (or let auto-compact fire) — no extra steps.

## How it works

1. **PreCompact**: back up the transcript and write a 10-heading state file via an LLM (`~/.claude/compact-ops/state/<cwd_hash>/<session_id>.md`)
2. **PostCompact**: reset the warning cooldown
3. **SessionStart (compact)**: inject recovery guidance into the fresh post-compaction context
4. **SessionStart (resume)**: inject this session's state, or the project's newest recent state
5. **UserPromptSubmit**: compute context usage from the transcript; above the threshold (default 60%), inject a one-shot `/compact` reminder plus a 3-line state recitation

All hooks fail open. Configuration is via `COMPACT_OPS_*` env vars in `~/.claude/settings.json` — see the [Japanese README](./README.ja.md) for the full table.

## License

MIT. Contains code derived from [u-ichi/compact-plus](https://github.com/u-ichi/compact-plus) (MIT).
