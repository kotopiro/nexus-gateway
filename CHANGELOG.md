# NEXUS Gateway — バグ修正ログ

## v0.1.4 (2026-06-21) — PostgreSQLスキーマ確定 + UUID変換バグ修正

CI (v0.1.3) がグリーンになったことを確認後、次の優先タスクとして
「PostgreSQLの実スキーマを先に決める」を選択。理由: `postgres.ex` は
既に `guild_members`/`channels`/`roles`/`member_roles`/`users` を
参照するクエリを書いていたが、それらを作る migration が一度も
存在せず、一度も実DBで検証されていなかった。

### 実施内容

1. **`migrations/` ディレクトリを新設**
   `golang-migrate` 互換形式 (`NNNNNN_name.up.sql`/`.down.sql`) で
   7つのテーブルを定義: `users`, `guilds`, `channels`, `roles`,
   `guild_members`, `member_roles`, `sessions`, `prekeys`, `mls_groups`。
   nexus-api (Go, 未実装) が将来そのまま `migrate` コマンドで使える形式。

2. **設計判断の明文化**: `channels.guild_id` は Layer 1/2 (DM/暗号化グループ)
   では実際の `guilds.id` を指さない「合成ルーティングID」であることを
   migration 内コメントと `migrations/README.md` に明記。
   既存のGatewayコード (`Guild.Process` が「1 guild_id = 1 GenServer」を
   前提にルーティングする設計) を変更せずに済むよう、この層で
   guild_id への外部キー制約を意図的に外した。

3. **実 PostgreSQL 16 でマイグレーションを実際に適用し、検証**
   ローカルに `apt-get install postgresql-16` でインスタンスを立て、
   7マイグレーションを順に適用 → テストデータ投入 →
   `postgres.ex` の4関数全てを実行して動作確認。

### 発見した実バグ: UUID文字列の Postgrex エンコードエラー

検証中に **新しい実バグ** を発見した:

```
DBConnection.EncodeError: Postgrex expected a binary of 16 bytes,
got "11111111-1111-1111-1111-111111111111"
```

Postgrex (Ecto非使用、生クライアント) の組み込み UUID extension は
**16バイトの生バイナリ以外を一切受け付けない**。文字列形式UUIDの
自動変換は行われない (Ectoを使えば `Ecto.UUID` 型が自動でやってくれるが、
nexus-gateway は意図的に Ecto を使わない設計のため、この変換を
自前で書く必要があった)。

JWT の `sub` クレームは常に文字列なので、Auth → transport.ex →
DataSource.Postgres という経路を通る `user_id`/`channel_id`/`guild_id`
は全て文字列形式。つまり **`postgres.ex` の4つの関数は、実際の
PostgreSQL接続が有効になった瞬間に100%失敗する状態だった**
(これまでテストされていなかったため検出されていなかった)。

**修正**: `postgres.ex` に `uuid_to_binary/1` (文字列→16バイト) と
`uuid_to_string/1` (16バイト→文字列) を追加し、全クエリの
パラメータ送信前・結果取得後の境界でこの変換を一元的に行うよう変更。
呼び出し元 (transport.ex, ChannelCache等) は影響を受けない
(常に文字列形式のUUIDを扱う前提は変えていない)。

修正後、実DB相手に8項目 (4関数 × 正常系/異常系) を再検証し、
全て期待通りの結果を確認:
```
fetch_guild_ids(alice)              -> {:ok, ["33333333-...-333"]}
fetch_guild_ids(存在しないユーザー)   -> {:ok, []}
fetch_guild_for_channel(general)    -> {:ok, "33333333-...-333"}
fetch_guild_for_channel(存在しないch) -> {:error, :not_found}
fetch_channel_permissions(alice)    -> {:ok, 3}  (view+send_messages)
fetch_channel_permissions(bob)      -> {:ok, 0}  (ロールなし)
fetch_guild_members(guild)          -> alice, bob 両方を正しく返す
Permissions.has?/2 の整合性          -> 全て期待通り
```

### 統合テスト追加

`test/nexus_gateway/data_source/postgres_test.exs` を新設
(`@tag :integration`、デフォルトの `mix test` では実行されない)。
実 PostgreSQL が必要なため CI には含めず、手元で実DBを立てた際に
`mix test --include integration` で実行する運用とした。

### 教訓 (またしても)

v0.1.2 → v0.1.3 で「実際に mix compile/test を回すことの重要性」を
学んだはずだったが、今回は **「実際にDBを繋いで動かす」ことの重要性**を
再確認した。Postgrex連携コードは構文的に正しく、コンパイルも通り、
mix testも (Stubにフォールバックする設計のため) 通っていたが、
実際のPostgreSQL接続が有効になった瞬間に確実に失敗する状態だった。
**「コンパイルが通る」「テストが通る」は、そのコードパスが実際に
実行されたことを意味しない。** DataSource.Postgresはconfig/test.exsで
Stubに強制されているため、mix testではこのモジュールのコードは
一度も実行されていなかった。

---

## v0.1.3 (2026-06-20) — CIグリーン化 + REQUEST_MEMBERS実装完了

開発の流れ: Claude (設計・v0.1.1/v0.1.2) → **Genspark** (実hex.pm環境でCI修正、
REQUEST_MEMBERS着手、クレジット切れで中断) → **Claude** (引き継ぎ完成)

### Genspark が発見・修正した実バグ (v0.1.2 では検出不能だった)

v0.1.2 の「検証」は Code.string_to_quoted による構文チェックと、
Postgrex/Gnat の実ソースとの API 照合のみで、**実際のコンパイル・実行は
していなかった**。Genspark は hex.pm に到達できる環境で実際に
`mix compile` / `mix test` / 実 WebSocket 接続を行い、以下の本物のバグを発見した:

1. **`Opcodes.identify()` をガード節で呼び出していた**
   Elixir はガード節内でリモート関数呼び出しを許可しない (コンパイルエラー)。
   `route/2` の `when` ガードを `cond do` ブロックに変更して修正。

2. **Phoenix 1.8 で `:transport_module` オプションが廃止されていた**
   `endpoint.ex` の `socket/3` 呼び出し方法が古い Phoenix API のままだった。
   Raw Transport モジュールを第2引数に直接渡す方式に変更し、
   不要になった `UserSocket` ラッパーを削除。
   さらに `websocket: [path: "/"]` が無いと実際のマウント先が
   `/gateway/v1/websocket` になってしまう問題も発見・修正。

3. **`RateLimiter` が `:bag` を使っていたため機能していなかった**
   `:bag` は完全に同一のタプルを重複排除する。`{key, timestamp_ms}` は
   同一ミリ秒内の複数リクエストで同じタプルになり、1件に潰れてしまう。
   `:duplicate_bag` に変更して修正 (これは静かに失敗するタイプの重大バグだった)。

4. **`Guild.Process` の join/leave で fanout に古い state を使っていた**
   `join` 時は新しい接続を含まない旧 state で fanout していたため、
   参加した本人が自分のオンライン通知を受け取れなかった。
   `leave` も同様に新 state を使っていたため、退出者が自分のオフライン
   通知を受け取れなかった。State の使い分けを修正。

5. **`HealthController` に `formats: [:json]` が必要 (Phoenix 1.8)**

6. **`child_spec/1` に `@impl true` が必要 (warnings-as-errors で検出)**

7. **`mix format --check-formatted` が大量の差分を検出**
   手書きコードの列揃えインデントが Elixir 標準フォーマッタと不一致。
   `mix format` を実行して解消。

8. **version 不整合**: `mix.exs` が `0.1.1`、CHANGELOG は `0.1.2` と表記。
   `Application.spec(:nexus_gateway, :vsn)` を使い、`mix.exs` の値を
   単一の真実源にするよう修正。

### REQUEST_MEMBERS (op:11) + GUILD_MEMBERS_CHUNK 実装完了

Genspark がクレジット切れで中断した箇所 (`filter_members/2`,
`maybe_limit/2`, `annotate_presence/2`, `send_member_chunks/3` が
呼び出されているが未定義) を引き継いで実装。

- `DataSource` behavior に `fetch_guild_members/1` を追加
  (Postgres実装 + Stub実装の両方)
- `Guild.Process.request_members/3` — 要求元にのみ
  `GUILD_MEMBERS_CHUNK` を返す (guild 全体への broadcast はしない)
- query (前方一致フィルタ) / limit に対応
- 1000件ごとのチャンク分割 (Discord 互換)
- 0件マッチでも終端チャンクを1件返し、クライアントを待たせない設計
- `transport.ex` の `on_request_members/2` を実装に接続
  (guild メンバーシップの検証付き)

### 検証方法 (このセッションで実施)

開発環境がさらに hex.pm に到達できない制約があったため:

1. Erlang 25 環境向けに **Elixir 1.16.3 をソースから git clone + `make` でビルド**
   (GitHub release バイナリは非対応ドメインへリダイレクトされるため不可)
2. `jose` ライブラリの `dynamic()` 型注釈 (OTP27限定) を `term()` に
   パッチ (型注釈のみで実行時動作に影響なし)
3. `rebar3` を apt から取得し、Mix が期待する `~/.mix/elixir/X-Y/rebar3`
   パスに配置
4. **`mix test --exclude integration`: 56 tests, 0 failures**
5. **`mix compile --warnings-as-errors`: 警告0件**
6. **`mix format --check-formatted`: 整形済み**
7. **実サーバー起動 + 実 WebSocket クライアント (Python) による E2E 検証**:
   HELLO → IDENTIFY → READY → REQUEST_MEMBERS → GUILD_MEMBERS_CHUNK
   (query フィルタ込み) → HEARTBEAT/ACK の全フローを実際に確認

### 教訓

v0.1.2 時点の「構文チェック + API照合による検証」は、実際にコードを
実行しなければ発見できない種類のバグ (ガード節の制約、ETSセマンティクス、
state の参照順序、フレームワークAPIの変更) を全く検出できなかった。
**実行を伴わない検証には限界がある。** 今回 Genspark が実環境で
mix compile/test を回したことで、上記8件の本物のバグが初めて発見された。

---

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
