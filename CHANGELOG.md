# NEXUS Gateway — バグ修正ログ

## v0.1.2 (2026-06-20) — 5つの優先TODO実装

antigravity の作業引き継ぎが途中で中断したため、残りを引き継いで実装。
DataSource behavior パターンの方針 (antigravity 提案) を採用。

### 実装内容

#### 1. fetch_guild_ids + find_guild_for_channel (DataSource behavior)

- **新規**: `lib/nexus_gateway/data_source.ex` — behavior 定義
- **新規**: `lib/nexus_gateway/data_source/stub.ex` — DB未接続時のフォールバック
- **新規**: `lib/nexus_gateway/data_source/postgres.ex` — Postgrex 実装
  - Pool 未起動時は自動的に Stub にフォールバックする (起動を妨げない)
- **新規**: `lib/nexus_gateway/channel_cache.ex` — ETS キャッシュ (TTL 5分)
- transport.ex の `fetch_guild_ids/1`、`find_guild_for_channel/2` を
  `DataSource` / `ChannelCache.get_or_fetch/1` 呼び出しに置き換え

#### 2. NATS JetStream 統合

- **新規**: `lib/nexus_gateway/nats/publisher.ex`
  - `gateway.message.e2ee.create` / `gateway.mls.commit` /
    `gateway.voice.join` / `gateway.voice.leave` を発行
  - NATS 未接続時は no-op (ログのみ、エラーにしない)
- **新規**: `lib/nexus_gateway/nats/consumer.ex`
  - `use Gnat.Server`、`dispatch.guild.*` / `dispatch.channel.*` /
    `dispatch.user.*` を購読
  - メッセージボディは `:erlang.binary_to_term/1` でデシリアライズ
- application.ex: `Gnat.ConnectionSupervisor` + `Gnat.ConsumerSupervisor` を
  NATS_URL 環境変数がある場合のみ追加

#### 3. レート制限

- **新規**: `lib/nexus_gateway/rate_limiter.ex` — ETS sliding window
  - 全 opcode: 120件/分 (per connection)
  - TYPING_START: 1件/3秒 (per user+channel)
  - E2EE_ENVELOPE: 20件/秒 burst, 5件/秒 sustained (per connection)
- transport.ex の `route/2` にグローバル制限、
  `on_typing_start/2` / `on_e2ee_envelope/2` に専用制限を追加

#### 4. チャンネル権限チェック

- **新規**: `lib/nexus_gateway/permissions.ex`
  - Discord ライクなビットフラグ (`view_channel` 〜 `administrator`)
  - `administrator` フラグは他の全権限を暗黙的に含む
  - `DataSource.fetch_channel_permissions/2` 経由で判定
- transport.ex の `on_typing_start/2` / `on_e2ee_envelope/2` に権限チェック追加
  (権限なし → エラーフレーム、接続は維持)

#### 5. MLS Welcome 個別配送

- **新規**: `lib/nexus_gateway/connection_registry.ex`
  - `Registry` (`:duplicate` keys) で user_id → [conn_pid] を管理
  - 複数デバイス接続に対応
- transport.ex の `on_identify/2` / `on_resume/2` で register、
  `terminate/2` で unregister
- `on_mls_commit/2`: welcomes を guild broadcast から
  `ConnectionRegistry.send_to_user/2` による個別配送に変更

### 検証方法 (ネットワーク制限下での対応)

開発環境が hex.pm に到達できない制約があったため、以下の方法で検証した:

1. **純粋構文チェック**: 全36ファイルを `Code.string_to_quoted/1` で検証 → 0エラー
2. **実コンパイル**: 外部ライブラリに依存しない自作ロジック9モジュール
   (Opcodes, Frame, Permissions, DataSource, Stub, ChannelCache,
   ConnectionRegistry, RateLimiter, Session.Store, Guild.Process,
   Guild.Supervisor) を相互参照込みで実際に `elixirc` でコンパイル → 0エラー
3. **API照合**: Postgrex / Gnat の実ソースを GitHub から取得し、
   使用している全関数 (`Postgrex.query/4`, `Postgrex.Result` 構造体,
   `Postgrex.child_spec/1`, `Gnat.pub/4`, `Gnat.ConnectionSupervisor`,
   `Gnat.ConsumerSupervisor`, `Gnat.Server` behaviour) の引数・戻り値の
   形を1つずつ照合 → 全て一致

フル `mix compile` (hex.pm 経由の全依存解決) は CI (GitHub Actions) で
実行されることを想定。ローカルでは上記の代替検証で品質を確保した。

---

## v0.1.1 (2026-05-31) — 起動バグ修正

### 発見されたバグ (antigravity による特定)

#### Bug 1: `Opcodes.hello/0` 未定義
- **場所**: `lib/nexus_gateway/nwp/opcodes.ex`
- **症状**: `NexusGateway.NWP.Opcodes.hello/0 is undefined or private` コンパイル警告
- **原因**: `transport.ex` で `Opcodes.hello()` を呼び出していたが、opcodes.ex に定義が存在しなかった
- **修正**: `def hello, do: 16` を追加 (NWP v1 仕様では opcode 16 = HELLO)

#### Bug 2: `child_spec/1 required by behaviour Phoenix.Socket.Transport is not implemented`
- **場所**: `lib/nexus_gateway/transport.ex`
- **症状**: コンパイル警告 + WebSocket が 404 を返す
- **原因**: `@behaviour Phoenix.Socket.Transport` を宣言しているが `child_spec/1` が未実装
- **修正A**: `def child_spec(_opts), do: :ignore` を追加
- **修正B**: `endpoint.ex` の socket mount を修正 (後述)

#### Bug 3: Phoenix.Socket.Transport の誤った mount 方法
- **場所**: `lib/nexus_gateway/endpoint.ex`
- **症状**: WebSocket /gateway/v1 が 404
- **原因**: `socket/3` は Phoenix.Socket モジュール用。Raw Transport を直接渡すと
          Phoenix が `child_spec/1` を探し、見つからず 404
- **修正**:
  - `NexusGateway.UserSocket` (use Phoenix.Socket) を新規作成
  - `endpoint.ex` を `socket "/gateway/v1", NexusGateway.UserSocket, websocket: [transport_module: NexusGateway.Transport, ...]` に変更

### 変更ファイル一覧

| ファイル | 変更内容 |
|----------|---------|
| `lib/nexus_gateway/nwp/opcodes.ex` | `def hello, do: 16` 追加 |
| `lib/nexus_gateway/transport.ex` | `def child_spec(_opts), do: :ignore` 追加 |
| `lib/nexus_gateway/endpoint.ex` | transport_module オプションで mount 方法修正 |
| `lib/nexus_gateway/user_socket.ex` | **新規**: Phoenix.Socket ラッパー |

### 起動確認コマンド

```powershell
cd nexus-gateway
mix deps.get
mix compile      # 警告ゼロを確認
mix phx.server   # [info] Running NexusGateway.Endpoint が出れば OK

# 別ターミナルで
curl http://localhost:4000/health
# → {"status":"ok","service":"nexus-gateway","version":"0.1.0"}

# WebSocket テスト (wscat が必要)
npx wscat -c "ws://localhost:4000/gateway/v1?v=1&encoding=msgpack"
# → binary frame が届けば HELLO 送信成功
```

### 反省

`opcodes.ex` に `hello` を定義し忘れたのは単純な記述漏れ。
`transport.ex` で `Opcodes.hello()` を参照しているにも関わらず確認しなかった。

Phoenix の Raw Transport mount 方法の誤解は、Phoenix.Socket.Transport と
Phoenix.Socket (channels) の役割を混同したことによる設計ミス。
