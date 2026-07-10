# compact-ops

[English README](./README.en.md)

[![GitHub Sponsors](https://img.shields.io/github/sponsors/kenimo49?logo=githubsponsors&label=Sponsor)](https://github.com/sponsors/kenimo49)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-tip-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/kenimo49)

![compact-ops hero](./docs/assets/hero.png)

Claude Code の context compaction を挟んでもセッションが壊れないようにする透過型プラグイン。圧縮前に構造化 state file を保存し、圧縮直後・resume 直後に復旧ガイダンスを注入する。圧縮アルゴリズム自体には手を入れず、公式 hook だけで完結する。

[u-ichi/compact-plus](https://github.com/u-ichi/compact-plus) (MIT) の設計をベースに、次の3点を変更した派生実装。

| | compact-plus | compact-ops |
|---|---|---|
| コンテキスト使用率の警告 | 作者の別リポジトリの statusline スクリプトが書く marker に依存（plugin 単体では発火しない） | **plugin 単体で完結**。UserPromptSubmit hook が transcript の最新 usage から使用率を自己計算 |
| state file の置き場所 | `$TMPDIR`（再起動で消える） | **`~/.claude/compact-ops/` に永続化**（30日保持）。プロジェクト cwd 別に整理 |
| セッション跨ぎの復旧 | なし（compact 跨ぎのみ） | **`--resume` 時に SessionStart hook が state を注入**。同一プロジェクトの直近 state への fallback つき（72h 以内） |
| 圧縮直後の復旧注入 | PostCompact marker → 次の UserPromptSubmit で注入（2 hook の間接構造） | SessionStart hook の `compact` matcher で直接注入 |
| 手動 state 保存 skill の session id 検出 | 作者の `~/.claude/scripts/get-session-id.sh` に依存 | **plugin に同梱** (`scripts/get-session-id.sh`) |
| LLM backend | Sonnet primary / Codex Spark fallback (ChatGPT Pro 前提) | Sonnet primary / **Haiku fallback**（Claude だけで完結） |

## compact すると何が起きるか — 標準との違い

Claude Code はコンテキストが埋まると、会話全体を built-in prompt で 1 本の summary に圧縮して古いメッセージを捨てる（`/compact` 手動、または auto-compact）。この summary が薄いと、圧縮後の agent は「どのファイルを編集中だったか」「何を決めて何を却下したか」「どのアプローチが既に失敗したか」を忘れて脱線する。これが compact 問題の実体で、compact-ops はこの summary を**置き換えるのではなく、外側から保険をかける**。

| タイミング | 標準の Claude Code のみ | compact-ops あり |
|---|---|---|
| 使用率 60% 超（閾値変更可） | 無警告。auto-compact は突然来る | `/compact` を切りのいい所で打つよう 1 回だけ通知 + 現在の Plan / Phase / 直近判断の 3 行 recitation を注入 |
| compact 実行の瞬間 | built-in prompt が summary を生成（中身は制御不可） | 同じ圧縮が走るのに**加えて**、transcript 全文を backup + 別 LLM (Sonnet) が 10 見出しの state file を書き出す |
| compact 直後の再開 | summary だけを頼りに継続 | 新コンテキストに state file + 「原文の再読を優先せよ」note + 呼び出し済み skill 一覧を注入 |
| セッションを閉じた後 | summary はそのセッション内にしか存在しない | state file が `~/.claude/compact-ops/` に 30 日残り、`claude --resume` 時も注入される（PC 再起動 OK） |
| hook が失敗した時 | — | fail-open。state 生成に失敗しても標準の compact はそのまま通る |

つまり圧縮後の agent は「標準 summary」と「構造化 state file」の**二重の手がかり**で再開する。state file は Active Plan / 残タスク / 判断と理由 / ブロッカー / 編集中ファイル / 失敗済みアプローチを見出し別に固定フォーマットで持つので、summary で薄まりがちな運用系の事実（「push は承認済み」「このアプローチは試して失敗した」など）が残る。ファイルとして残るので、人間が後から読んで引き継ぎ内容を確認することもできる。

変わらないもの・コスト:

- 圧縮アルゴリズムと標準 summary の品質そのものは変わらない（公式 hook の外付けのみ）
- state file は原文（プロジェクトファイル・plan・skill）より authoritative ではない。復旧ガイダンスも常に原文再読を促す
- compact 1 回ごとに state 生成の LLM 呼び出しが 1 回増える（default: Sonnet。`COMPACT_OPS_PRIMARY_BACKEND` で Haiku に下げたり空文字列で無効化も可）

## 何ができるか

- 圧縮前に transcript を `~/.claude/compact-ops/backups/` にバックアップ (gzip 圧縮) し、LLM で 10 見出しの state file を書き出す
- 圧縮直後の新しいコンテキストに、state file・原文再読 note・呼び出し済み skill 一覧の復旧ガイダンスを注入する
- `claude --resume` した時も同じ復旧ガイダンスを注入する（PC 再起動を挟んでも state は残っている）
- コンテキスト使用率が閾値（default 60%）を超えたら `/compact` を推奨する通知と、Active Plan / Current Phase / 直近 Session Decision の 3 行 recitation を注入する
- `/compact-ops` skill で agent 自身が構造化 state を書く手動経路もある

## インストール

```bash
git clone https://github.com/kenimo49/compact-ops.git
claude plugin marketplace add /path/to/compact-ops --scope user
claude plugin install compact-ops@compact-ops-local
```

前提: Claude Code v2.x、`jq`、LLM backend として `claude` CLI。Linux / macOS 対応 (ハッシュは `md5sum` → `md5` → `shasum` の順で fallback、GNU 専用オプションは不使用)。

インストール後は普通に `/compact` を実行するだけで動く。追加の操作は不要。

## 設定

`~/.claude/settings.json` の `env` block で上書きする。

| env var | default | 意味 |
|---|---|---|
| `COMPACT_OPS_PRIMARY_BACKEND` | `claude -p --model claude-sonnet-5 ...` | state 生成の primary コマンド。空文字列で skip |
| `COMPACT_OPS_FALLBACK_BACKEND` | `claude -p --model claude-haiku-4-5-20251001 ...` | fallback コマンド。空文字列で skip |
| `COMPACT_OPS_WARN_THRESHOLD` | `60` | 使用率警告の閾値 (%) |
| `COMPACT_OPS_CONTEXT_WINDOW` | `200000` | 使用率計算に使う context window トークン数 |
| `COMPACT_OPS_RESUME_MAX_AGE_HOURS` | `72` | resume 復旧で拾う state の鮮度上限 |
| `COMPACT_OPS_TRANSCRIPT_MODE` | `incremental` | `incremental` / `head-tail` / `tail` |
| `COMPACT_OPS_TRANSCRIPT_HEAD_TURNS` | `5` | head 側で切り出す turn 数 |
| `COMPACT_OPS_TRANSCRIPT_TAIL_TURNS` | `25` | tail 側で切り出す turn 数 |
| `COMPACT_OPS_TRANSCRIPT_HEAD_KB` | `10` | head 側 byte cap (KB) |
| `COMPACT_OPS_TRANSCRIPT_TAIL_KB` | `40` | tail 側 byte cap (KB) |
| `COMPACT_OPS_INCREMENTAL_REFRESH` | `10` | N 回に 1 回全再構築。`0` で無効 |
| `COMPACT_OPS_MAX_OUTPUT_TOKENS` | `4096` | LLM 出力上限 |
| `COMPACT_OPS_SQUASH_ENABLED` | `1` | tool 出力 squash on/off |
| `COMPACT_OPS_SQUASH_READ_LINES` | `100` | Read 出力の squash 閾値（行） |
| `COMPACT_OPS_SQUASH_BASH_CHARS` | `500` | Bash 出力の squash 閾値（文字） |
| `COMPACT_OPS_TWO_PASS` | `1` | state 生成の 2-pass 自己批評 on/off (`0` で draft 一発出力に切替) |
| `COMPACT_OPS_HOME` | `~/.claude/compact-ops` | 永続データの置き場所 |
| `COMPACT_OPS_DEBUG` | `0` | `1` で fail-open が握りつぶした失敗理由を `$COMPACT_OPS_HOME/logs/compact-ops.log` に記録 (backend の stderr も `backend-stderr.log` に残す) |

backend コマンド内では `$SYSTEM_PROMPT` / `$SESSION_ID` / `$TRANSCRIPT_PATH` / `$MAX_OUTPUT_TOKENS` を参照できる。

`/compact 重要な設計判断は必ず残して` のように引数を付けると、state 生成 LLM への priority guidance になる。

## 動作フロー

1. **PreCompact**: transcript backup + LLM による 10 見出し state file 生成（`~/.claude/compact-ops/state/<cwd_hash>/<session_id>.md`）
2. **PostCompact**: 警告 cooldown をリセット
3. **SessionStart (compact)**: 圧縮直後の新コンテキストに復旧ガイダンスを注入
4. **SessionStart (resume)**: セッション再開時に自セッションの state、なければ同一プロジェクトの直近 state (72h) を注入
5. **UserPromptSubmit**: transcript の最新 assistant usage から使用率を計算し、閾値超過で `/compact` 推奨 + 3 行 recitation を一度だけ注入

全 hook が fail-open。hook が失敗しても compaction・prompt 処理は止まらない。原因調査が必要な時は `COMPACT_OPS_DEBUG=1`。

既知の制限: 使用率警告は UserPromptSubmit 時にしか計算できないため、次のユーザー発話より先に auto-compact が走るケース (1 turn で大量のコンテキストを消費した場合) は事前警告できない。その場合も PreCompact の state 保存自体は通常どおり動く。

## セキュリティと保持ポリシー

- state file と transcript backup には**会話内容がそのまま残る** (ツール出力経由で secrets が写り込む可能性もある)。すべて `umask 077` で作成され、ディレクトリ 700 / ファイル 600 でユーザー専用
- state: 30 日で自動削除。backup: session ごと最大 20 件 + 30 日で自動削除 (gzip 圧縮、JSONL は約 1/10 に縮む)
- `session_id` は allowlist 検証してからファイル名に使う (hook 入力を無検証でパスに流さない)
- LLM が生成した state は 10 見出し全部の存在を検証してから書き込む。不正な出力なら旧 state を保持したまま fail-open

## state file 見出し構成

`# Compact Prep State` から始まる 10 見出し。LLM 生成と `/compact-ops` 手動保存の両方で同じ順序を使う。

1. `## Active Plan`
2. `## Current Phase`
3. `## TaskList Summary`
4. `## Session Decisions`
5. `## Constraints and Blockers`
6. `## Worker Topology`
7. `## Skills Invoked`
8. `## Editing Files`
9. `## Failed Attempts`
10. `## Recovery Notes`

state file は原文の project files / rules / skills / plans より authoritative ではない。復旧ガイダンスは常に原文の再読を促す。

## Development Checks

```bash
python3 -m json.tool .claude-plugin/plugin.json >/dev/null
python3 -m json.tool .claude-plugin/marketplace.json >/dev/null
python3 -m json.tool hooks/hooks.json >/dev/null
bash -n hooks/*.sh scripts/*.sh
```

## License

MIT。[u-ichi/compact-plus](https://github.com/u-ichi/compact-plus) (MIT) 由来のコードを含む。

---

このツールが役に立ったら、[GitHub Sponsors](https://github.com/sponsors/kenimo49) で継続的なメンテナンスを支援できます。
