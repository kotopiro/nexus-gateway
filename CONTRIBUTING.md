# Contributing to nexus-gateway

## 開発環境セットアップ

```bash
mix local.hex --force
mix local.rebar --force
mix deps.get
mix test
```

## 設計原則 (必読)

このプロジェクトには曲げられない設計原則がある。PRを送る前に確認すること。

1. **E2EE Blob を復号しない** — `transport.ex` や `Guild.Process` は
   `payload` フィールドの内容を一切解釈・復号してはならない。
   サーバーが知っていいのは sender_id, channel_id, timestamp, payload_size のみ。

2. **独自暗号を実装しない** — libsignal (Signal Protocol) と OpenMLS (RFC 9420)
   以外の暗号プリミティブをこのリポジトリに追加しない。

3. **GraphQL を追加しない** — REST + WebSocket (NWP v1) のみ。

4. **公開鍵を Vault に置かない** — 長期秘密鍵のみ Vault。
   PreKey/Identity Key の公開鍵は PostgreSQL (`DataSource`)。

5. **外部依存はすべて `DataSource` behavior 経由** — `transport.ex` から
   `Postgrex` や他の DB クライアントを直接呼ばない。

## PR チェックリスト

- [ ] `mix format` を実行した
- [ ] `mix compile --warnings-as-errors` が通る
- [ ] `mix test` が通る (新規ロジックには対応するテストを追加)
- [ ] NWP v1 の Opcode/イベント名を変更する場合は `NEXUS_GATEWAY_NWP_v1.md` も更新する
- [ ] 外部 DB/NATS が未接続でも `mix phx.server` が起動することを確認した
      (DataSource.Stub / NATS no-op フォールバックが機能しているか)

## コミットメッセージ

日本語・英語どちらでも可。Conventional Commits 形式を推奨:

```
feat: MLS Welcome の個別配送を実装
fix: Opcodes.hello/0 の定義漏れを修正
test: RateLimiter のユニットテストを追加
docs: README にWindows手順を追加
```
