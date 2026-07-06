# Changelog

## 0.2.0 (2026-07-07)

自分のコードレビュー × codex 二段レビューの統合リストから、public 化前提の堅牢化を一括適用。

- **デバッグログ**: `COMPACT_OPS_DEBUG=1` で fail-open が握りつぶした失敗理由を `logs/compact-ops.log` に記録。backend の stderr も `logs/backend-stderr.log` に保存
- **パーミッション**: 全 hook で `umask 077`。state / backup / logs はディレクトリ 700・ファイル 600
- **session_id 検証**: hook 入力の `session_id` を allowlist (`^[A-Za-z0-9][A-Za-z0-9._-]*$`, `..` 拒否) で検証してからファイル名・glob・削除に使用
- **state 出力検証の強化**: 1 行目チェックのみ → 10 見出し全部の存在検証。不正な LLM 出力では旧 state を上書きしない (primary 不正時は fallback backend を試行)
- **resume fallback の対象を valid state に限定**: `# Compact Prep State` ヘッダを持つファイルのみ拾う (壊れた state や無関係な markdown を注入しない)
- **squash の単一パス化**: transcript 1 行ごとに jq を 3-4 回 spawn していたループを `hooks/squash.jq` の 1 プロセスに統合 (大きい incremental diff での timeout リスク解消)。あわせて squash プレースホルダの refs がファイル内容の生文字列を巻き込む上流由来の潜在バグを scan() トークン抽出 + 300 字 cap に修正
- **backup の gzip 化**: JSONL は約 1/10 に圧縮。`gzip` 不在環境は plain copy に fallback
- **macOS/BSD 対応**: `md5sum` → `md5` → `shasum` fallback、GNU 専用の `xargs -r` を除去
- **`COMPACT_OPS_TWO_PASS` の実装/ドキュメント乖離解消**: `0` で 2-pass 自己批評を実際にスキップする指示をプロンプトに注入
- **marketplace 配布の symlink 除去**: `plugins/compact-ops -> ..` の circular symlink (Windows / ZIP ダウンロードで壊れる) を廃止し、`source: "./"` に変更 (ローカル e2e で install 検証済み)

## 0.1.0 (2026-07-06)

初版。[u-ichi/compact-plus](https://github.com/u-ichi/compact-plus) (MIT) 派生:
単体完結の使用率警告 / `~/.claude/compact-ops` への state 永続化 (30 日) /
SessionStart hook による compact 直後 + resume 時の復旧注入 / Claude-only backend
(Sonnet primary, Haiku fallback)。
