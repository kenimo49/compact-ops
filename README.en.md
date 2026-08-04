# compact-ops

[日本語 README](./README.md)

[![Part of kenimoto Claude Code Kit](https://img.shields.io/badge/Part_of-kenimoto_Claude_Code_Kit-1E3A5F?style=flat-square)](https://github.com/kenimo49#kenimoto-claude-code-kit)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/kenimo49?logo=githubsponsors&label=Sponsor)](https://github.com/sponsors/kenimo49)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-tip-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/kenimo49)

> Part of the **[kenimoto Claude Code Kit](https://github.com/kenimo49#kenimoto-claude-code-kit)** — long-session survival tools for Claude Code. Siblings: [claude-shift](https://github.com/kenimo49/claude-shift) (multi-account switch + usage observer) / [hook-chain-lens](https://github.com/kenimo49/hook-chain-lens) (see how your hooks across user / project / plugin scopes actually merge and fire).

![compact-ops hero](./docs/assets/hero.png)

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

Requires Claude Code v2.x, `jq`, and the `claude` CLI as the LLM backend. Linux and macOS are supported (hashing falls back `md5sum` → `md5` → `shasum`; no GNU-only options).

After installing, just run `/compact` (or let auto-compact fire) — no extra steps.

## What changes when you compact

Standard Claude Code compresses the whole conversation into a single built-in summary and discards the old messages. When that summary comes out thin, the post-compaction agent forgets which files it was editing, what was decided (and rejected), and which approaches already failed. compact-ops does not replace that summary — it adds insurance around it:

| Moment | Standard Claude Code | With compact-ops |
|---|---|---|
| Context usage passes 60% (configurable) | No warning; auto-compact hits without notice | One-shot reminder to `/compact` at a clean stopping point, plus a 3-line recitation of the current plan / phase / latest decision |
| At compact time | Built-in prompt writes the summary (not controllable) | Same compression runs, **plus** the transcript is backed up and a separate LLM (Sonnet) writes a 10-heading state file |
| Right after compact | The agent continues from the summary alone | Recovery guidance is injected into the fresh context: the state file, a "re-read the originals first" note, and the list of invoked skills |
| After the session ends | The summary exists only inside that session | The state file persists under `~/.claude/compact-ops/` for 30 days and is re-injected on `claude --resume`, even across reboots |
| If a hook fails | — | Fail-open: standard compaction proceeds untouched |

So the post-compaction agent restarts with two anchors instead of one: the standard summary plus a structured state file holding the active plan, remaining tasks, decisions with reasons, blockers, files being edited, and failed attempts. The state file is a plain markdown file, so you can also read it yourself to see what was handed over.

What does not change: the compaction algorithm and the standard summary itself are untouched; the state file is never more authoritative than the original project files; and each compact costs one extra LLM call (default Sonnet — downgrade to Haiku or disable via `COMPACT_OPS_PRIMARY_BACKEND`).

## How it works

1. **PreCompact**: back up the transcript (gzip) and write a 10-heading state file via an LLM (`~/.claude/compact-ops/state/<cwd_hash>/<session_id>.md`); the LLM output is only written after all 10 headings validate, otherwise the previous state is kept
2. **PostCompact**: reset the warning cooldown
3. **SessionStart (compact)**: inject recovery guidance into the fresh post-compaction context
4. **SessionStart (resume)**: inject this session's state, or the project's newest recent state
5. **UserPromptSubmit**: compute context usage from the transcript; above the threshold (default 60%), inject a one-shot `/compact` reminder plus a 3-line state recitation

All hooks fail open; set `COMPACT_OPS_DEBUG=1` to log swallowed failures under `~/.claude/compact-ops/logs/`. Configuration is via `COMPACT_OPS_*` env vars in `~/.claude/settings.json` — see the [Japanese README](./README.md) for the full table.

Security and retention: state files and backups carry raw conversation content (secrets echoed by tools included), so everything is created with `umask 077` (dirs 700 / files 600). State is pruned after 30 days; backups keep at most 20 per session and 30 days. Known limitation: the usage warning can only be computed on UserPromptSubmit, so an auto-compact that fires before your next prompt gets no advance warning (state capture still runs).

## License

MIT. Contains code derived from [u-ichi/compact-plus](https://github.com/u-ichi/compact-plus) (MIT).

---

If this project saved you time, you can [sponsor its continued maintenance](https://github.com/sponsors/kenimo49).
