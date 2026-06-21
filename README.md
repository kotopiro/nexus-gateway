# nexus-gateway

NEXUS リアルタイム WebSocket ゲートウェイ。
NWP v1 プロトコル / Elixir + Phoenix 実装。

[![CI](https://github.com/kotopiro/nexus-gateway/actions/workflows/ci.yml/badge.svg)](https://github.com/kotopiro/nexus-gateway/actions/workflows/ci.yml)

## 必要環境

| ツール     | バージョン |
|-----------|----------|
| Elixir    | 1.14+    |
| Erlang/OTP| 25+      |

### インストール (Ubuntu/Debian)

```bash
sudo apt install elixir erlang-dev erlang-crypto erlang-ssl erlang-inets erlang-runtime-tools
```

### インストール (asdf を使う場合)

```bash
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 26.2.5
asdf install elixir 1.16.3-otp-26
asdf global erlang 26.2.5
asdf global elixir 1.16.3-otp-26
```

### インストール (Windows)

1. [Erlang](https://www.erlang.org/downloads) と [Elixir](https://elixir-lang.org/install.html#windows) をインストール
2. `elixir -v` で確認
3. PowerShell で IEx を使う場合は `iex.bat -S mix phx.server`
   (`iex` だけだと `Invoke-Expression` のエイリアスと衝突する)

## セットアップ

```bash
mix local.hex --force
mix local.rebar --force
mix deps.get

# 環境変数 (省略時はデフォルト値 + Stub/no-op フォールバックで動作する)
export JWT_SECRET="dev_secret_CHANGE_IN_PROD"
export GATEWAY_URL="ws://localhost:4000/gateway/v1"
# export POSTGRES_URL="postgresql://nexus:password@localhost:5432/nexus_dev"
# export NATS_URL="nats://localhost:4222"

mix phx.server
```

`POSTGRES_URL` / `NATS_URL` を設定しなくても起動できる。
その場合 `DataSource.Postgres` は自動的に `DataSource.Stub` の挙動にフォールバックし、
NATS 統合は no-op になる (ログに warning が出るだけ)。

## テスト

```bash
mix test                       # integration タグは除外される
mix test --include integration # 実 DB/NATS が必要なテストも実行
mix test --trace                # 詳細表示
```

## 動作確認

```bash
npm install -g wscat
wscat -c "ws://localhost:4000/gateway/v1?v=1&encoding=msgpack"

curl http://localhost:4000/health
```

## アーキテクチャ

```
Client (WebSocket)
  ↓
NexusGateway.UserSocket      # Phoenix.Socket ラッパー (チャンネルは使わない)
  ↓ transport_module:
NexusGateway.Transport       # NWP v1 フレーム処理 (本体)
  ├─→ RateLimiter            # opcode別レート制限 (ETS)
  ├─→ Permissions            # 権限チェック (DataSource経由)
  ├─→ DataSource             # guild_ids / channel→guild / 権限 (Postgres or Stub)
  ├─→ ChannelCache           # channel_id → guild_id キャッシュ (TTL 5分)
  ├─→ ConnectionRegistry     # user_id → conn_pid (MLS Welcome個別配送等)
  └─→ NATS.Publisher         # nexus-api / nexus-media への発行 (no-op フォールバック)
  ↓
NexusGateway.Guild.Process   # Guild ごとの GenServer (Presence + fanout)
  ↓
send/2 → Transport.handle_info({:dispatch, event})
  ↓
Client (Push)

NATS.Consumer (Gnat.Server) ← nexus-api からの dispatch.* イベントを購読
```

## モジュール一覧

| モジュール | 責務 |
|-----------|------|
| `Transport` | NWP v1 フレームのルーティング (本体) |
| `UserSocket` | Phoenix.Socket ラッパー |
| `Guild.Process` | 1 Guild = 1 GenServer。Presence・fanout・Typing |
| `Guild.Supervisor` | GuildProcess の DynamicSupervisor |
| `Session.Store` | ETS セッション + RESUME 用イベントバッファ |
| `DataSource` | 外部データアクセスの behavior 抽象化 |
| `DataSource.Postgres` | PostgreSQL 実装 (Pool未起動時は自動フォールバック) |
| `DataSource.Stub` | DB未接続時のダミー実装 (常に許可) |
| `ChannelCache` | channel_id→guild_id の ETS キャッシュ |
| `ConnectionRegistry` | user_id→conn_pid (複数デバイス対応) |
| `RateLimiter` | ETS sliding window レート制限 |
| `Permissions` | 権限ビットフラグ判定 |
| `NATS.Publisher` | NATS への発行 (no-opフォールバック付き) |
| `NATS.Consumer` | NATS からの dispatch イベント購読 (`Gnat.Server`) |
| `Auth` | JWT 検証 (HS256, Joken) |
| `NWP.Frame` | MessagePack encode/decode |
| `NWP.Opcodes` | Opcode 定数 (0〜16) |

## 今後の実装 (TODO)

- [ ] `mix deps.get` の CI 経由フル検証 (開発時は hex.pm 到達不可な制約があった)
- [x] REQUEST_MEMBERS (`GUILD_MEMBERS_CHUNK` 配信)
- [ ] Horde + libcluster (マルチノードクラスタ)
- [ ] 負荷テスト (1000 並列接続)
- [ ] Sealed Sender (送信者ID露出削減)
- [ ] WebPush 暗号化 Push通知 (Phase 2)

## 設計ドキュメント

詳細は以下を参照:

- `NEXUS_GATEWAY_NWP_v1.md` — NWP v1 プロトコル完全仕様
- `NEXUS_ARCHITECTURE_v0.2.md` — システム全体アーキテクチャ
- `CHANGELOG.md` — 変更履歴とバグ修正記録
- `CONTRIBUTING.md` — 開発時の設計原則

## ライセンス

MIT — `LICENSE` 参照
