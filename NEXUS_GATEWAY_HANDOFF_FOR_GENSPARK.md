# NEXUS Gateway — 引き継ぎ書 v3 (Genspark 向け)

> **これが正本です。** これまでの HANDOFF / 引き継ぎ書 v1・v2 は
> このドキュメントで置き換える。状態が大きく進んだので、まずこれを通読してほしい。

開発の流れ:

```
Claude  : 設計・v0.1.1 / v0.1.2 (hex.pm 不達のため compile/test できず、構文確認のみ)
Genspark: 実 hex.pm 環境で CI 修正に着手、REQUEST_MEMBERS 着手、クレジット切れで中断
Claude  : 引き継ぎ完成 → v0.1.3 (CI 確認済みグリーン)
Claude  : PostgreSQL 実スキーマ確定 + 実バグ修正 → v0.1.4
Claude  : v0.1.4 アーカイブを実環境 (Elixir 1.18.3 / OTP 27, hex.pm 到達可) で再検証 ← 今ここ
         → あなた (Genspark) へ
```

---

## 0. 最初に: 状態は良好。すべて検証済み

このセッションで、これまでの全成果物 (`v0.1.4` アーカイブ + git 履歴) を
**hex.pm に到達できる実環境で再ビルド・再テストし、グリーンを確認した。**

```
$ mix deps.get                       → 成功 (hex.pm 到達可)
$ mix compile --warnings-as-errors   → 成功 (警告 0)
$ mix format --check-formatted       → クリーン
$ mix test --exclude integration     → 64 tests, 0 failures, 8 excluded
```

環境: Erlang/OTP 27 (erts 15.2.7) / Elixir 1.18.3。
（CI マトリクスは OTP 26.2 / Elixir 1.16.3 だが、この環境でも問題なく通る。
`mix.exs` は `elixir: "~> 1.15"`、Postgrex 0.22 が 1.15+ を要求するため。）

過去に見つけた 8 個のバグは全部本物で、修正方針も適切だった。
さらに 2 つ前進している:

1. 中断していた **REQUEST_MEMBERS (op:11)** の実装を完成 (v0.1.3)
2. **PostgreSQL の実スキーマ**を新規作成し、実 DB で検証して
   新しい実バグ (UUID エンコードエラー) を発見・修正 (v0.1.4)

---

## 1. リポジトリの現在状態 (v0.1.4)

### git

```
ブランチ: main
remote  : https://github.com/kotopiro/nexus-gateway.git
コミット:
  53b2256 feat: define PostgreSQL schema + fix critical UUID encoding bug   (v0.1.4)
  98bc17e fix: resolve CI failures + complete REQUEST_MEMBERS implementation (v0.1.3)
  9197c84 Update README.md
  b2aee26 Update README.md
  c03f793 feat: implement 5 priority TODOs (...)

status: origin/main より 2 コミット先行 (53b2256, 98bc17e は未 push の可能性あり)
        → push 前に必ず最新の origin/main を fetch して状態を確認すること。
```

### 実装済み (動作確認済み)

```
✅ NWP v1 プロトコル全体 (HELLO/HEARTBEAT/IDENTIFY/READY/RESUME/DISPATCH/
   REQUEST_MEMBERS/E2EE_ENVELOPE/MLS_COMMIT/MLS_WELCOME ...)
✅ JWT (HS256, Joken) 認証 / Session.Store (RESUME バッファ, ETS)
✅ ConnectionRegistry / RateLimiter (:duplicate_bag) / Permissions (bitflags)
✅ Guild.Process (1 guild_id = 1 GenServer, presence/typing/voice/fanout)
✅ NATS Publisher/Consumer (未接続時は no-op フォールバック)
✅ REQUEST_MEMBERS (op:11) + GUILD_MEMBERS_CHUNK 完成
✅ PostgreSQL 実スキーマ (migrations/ に7マイグレーション、実DB検証済み)
✅ DataSource.Postgres の UUID 変換バグ修正 (下記 §3 参照、重要)
```

### v0.1.3 / v0.1.4 で追加されたファイル

```
migrations/
  000001_create_users.up.sql / .down.sql
  000002_create_guilds.up.sql / .down.sql
  000003_create_channels.up.sql / .down.sql            ← 必読コメントあり
  000004_create_roles_and_membership.up.sql / .down.sql
  000005_create_sessions.up.sql / .down.sql
  000006_create_prekeys.up.sql / .down.sql
  000007_create_mls_groups.up.sql / .down.sql
  README.md                                            ← 設計判断の説明、必読

test/nexus_gateway/data_source/postgres_test.exs  (@tag :integration, 実DB必要)
test/nexus_gateway/data_source/stub_test.exs
test/nexus_gateway/guild/request_members_test.exs
```

---

## 2. これまでに修正した 8 個の実バグ (v0.1.2 → v0.1.3)

前任者 (Claude / Genspark) が hex.pm に到達できず compile/test できなかった
ために潜んでいた、「実際にビルド・実行して初めて表面化する」バグ。

| # | ファイル | 症状 | 修正 |
|---|---------|------|------|
| 1 | `endpoint.ex` | Phoenix 1.8 で `:transport_module` が廃止 | raw transport を `socket/3` の第2引数に直接 mount。`websocket: [path: "/", ...]` ← `path: "/"` が必須 (既定の `/websocket` だと URL が `/gateway/v1/websocket` になる) |
| 2 | `transport.ex` | `route/2` のガード節で `Opcodes.identify()` 等のリモート関数呼び出し → コンパイルエラー | ガードをやめ `cond do` で判定 |
| 3 | `transport.ex` | `child_spec/1` に `@impl true` 欠落で警告 | `@impl true` 付与 (`def child_spec(_opts), do: :ignore`) |
| 4 | `health_controller.ex` | `:formats` 未指定 | `use Phoenix.Controller, formats: [:json]` + version を動的取得 |
| 5 | `rate_limiter.ex` | ETS `:bag` は完全一致タプルを重複排除 → 同一ミリ秒の `{key, ts}` が潰れ、**レート制限が一切機能しない** | `:duplicate_bag` に変更 |
| 6 | `guild/process.ex` | join/leave の fanout が誤った state スナップショットを使用 | join → `new_state` (joiner を含む) / leave → 旧 `state` (leaver をまだ含む) を使用 |
| 7 | 全体 | `mix format --check-formatted` 不合格 (CI 必須) | `mix format` 適用 |
| 8 | `mix.exs` / `CHANGELOG` | バージョン不整合 (0.1.1 vs 0.1.2) | 整合 |

---

## 3. v0.1.4 で発見した重大バグ (必読): UUID 文字列の Postgrex エンコードエラー

`lib/nexus_gateway/data_source/postgres.ex` は当初、`user_id` / `channel_id` /
`guild_id` 等の文字列形式 UUID (`"11111111-1111-1111-1111-111111111111"`)
をそのまま `Postgrex.query/3` に渡していた。

**これは実 PostgreSQL に接続した瞬間に 100% 失敗する:**

```
DBConnection.EncodeError: Postgrex expected a binary of 16 bytes,
got "11111111-1111-1111-1111-111111111111"
```

Postgrex (Ecto 非使用の生クライアント) の組み込み UUID extension は
**16 バイトの生バイナリ以外を一切受け付けない** (文字列の自動変換なし。
Ecto を使えば自動だが、本プロジェクトは設計原則 §5 のため意図的に Ecto を使わない)。

JWT の `sub` クレームは常に文字列なので、このバグはコードパス全体に影響していた。

**`mix test` で検出されなかった理由**: `config/test.exs` が `DataSource.Stub` を
強制しているため、`DataSource.Postgres` のコードはテストで一度も実行されて
いなかった。「コンパイルが通る」「`mix test` が通る」は、そのコードパスが
実際に実行されたことを意味しない。実 DB に繋いで動かすまで検出不可能だった。

**修正**: `postgres.ex` に `uuid_to_binary/1` / `uuid_to_string/1` を追加し、
**Postgrex との境界でのみ**変換する設計にした。呼び出し元
(`transport.ex`, `ChannelCache` 等) は変更不要 — 常に文字列 UUID を扱う。

> 新しいクエリを `postgres.ex` に追加する際は **必ず** `uuid_to_binary/1` /
> `uuid_to_string/1` を経由すること。

---

## 4. PostgreSQL スキーマの設計判断 (必読)

詳細は `migrations/README.md` と各 `.up.sql` のコメントにあるが、要点を再掲する。

### 4.1 `channels.guild_id` は Layer 1/2 では「合成ルーティングID」

Gateway の既存コードは「1 guild_id = 1 GenServer」を前提に、チャンネル種別
(layer) を問わず必ず `channel_id -> guild_id` が 1 件取れることを期待している。
既存コードを変えずに済むよう、**スキーマ側で吸収**した:

```
layer = 3 (Community)        : guild_id は実際の guilds.id を指す
layer = 1 (Private DM, 1:1)  : guild_id は会話ごとに発行する合成 UUID
layer = 2 (Encrypted Group)  : guild_id はグループごとに発行する合成 UUID
```

`channels.guild_id` に **外部キー制約を付けていない**のはこのため
(layer=1/2 では `guilds` の実在行を指さない)。整合性保証は nexus-api の責務。

> nexus-api (Go) でチャンネル作成時:
> - layer=3 → `guild_id` = 既存 `guilds.id`
> - layer=1 → `guild_id` = `gen_random_uuid()` (会話ごと新規)
> - layer=2 → `guild_id` = `gen_random_uuid()` (暗号化グループごと新規)

### 4.2 その他の設計判断

- **UUID はバイナリ保存**、文字列との変換はアプリ層 (§3 参照)。
- **`member_roles` は `guild_members` への複合 FK** を持つ
  (`(user_id, guild_id)`)。ギルド未参加のユーザーにロールだけ付与する
  状態を DB レベルで防止。
- **`prekeys` は公開鍵のみ** (設計原則 §4: 公開鍵は PostgreSQL、長期秘密鍵は Vault)。
- **E2EE Blob (`payload`) はスキーマにも保存しない / 復号しない**
  (設計原則 §1)。サーバーが知るのは sender_id / channel_id / timestamp /
  payload_size のみ。
- **`mls_groups`** は MLS (RFC 9420) グループ状態の公開メタデータのみ。

### 4.3 検証済み

実 PostgreSQL 16 に 7 マイグレーションを順に適用 → テストデータ投入 →
`postgres.ex` の 4 関数 (`fetch_guild_ids/1`, `fetch_guild_for_channel/1`,
`fetch_channel_permissions/2`, `fetch_guild_members/1`) 全てを実行して
結果を確認済み (`postgres_test.exs`, `@tag :integration`)。

---

## 5. REQUEST_MEMBERS (op:11) / GUILD_MEMBERS_CHUNK の実装

Discord 互換の挙動:

- `DataSource.fetch_guild_members/1` (behavior + Postgres + Stub) で取得
- `Guild.Process.request_members/3` が **要求元の接続プロセスにのみ**返す
  (broadcast しない)
- `query` による user_id 前方一致フィルタ、`limit`、1000 件ごとのチャンク分割
- 0 件でも終端の空チャンクを 1 件必ず送る (クライアントを待たせない)
- `DataSource` が失敗しても空の終端チャンクを送るフェイルセーフ
- 各メンバーに presence (`online`/`offline`) を注釈

該当: `lib/nexus_gateway/guild/process.ex`
(`request_members/3`, `handle_cast({:request_members, ...})`,
private: `filter_members/2`, `maybe_limit/2`, `annotate_presence/2`,
`send_member_chunks/3`)。

---

## 6. 動作確認の手順

```bash
git clone https://github.com/kotopiro/nexus-gateway.git
cd nexus-gateway
mix local.hex --force
mix local.rebar --force
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test --exclude integration          # 64 tests, Stub 経由, DB 不要

# 外部 DB/NATS 未接続でも起動することの確認 (設計原則: フォールバック)
mix phx.server
curl http://localhost:4000/health        # {"status":"ok","version":"0.1.4",...}

# WebSocket 疎通 (例: ws://localhost:4000/gateway/v1?v=1&encoding=msgpack)
#   接続直後に HELLO (op:16, heartbeat_interval) が届けば OK

# PostgreSQL 統合テスト (実 DB が必要な場合のみ)
createdb nexus_dev
psql -d nexus_dev -c "CREATE USER nexus WITH PASSWORD 'nexus_dev_pass' SUPERUSER;"
for f in migrations/*.up.sql; do psql -d nexus_dev -U nexus -v ON_ERROR_STOP=1 -f "$f"; done
export POSTGRES_HOST=localhost POSTGRES_USER=nexus \
       POSTGRES_PASSWORD=nexus_dev_pass POSTGRES_DB=nexus_dev
mix test --include integration
```

---

## 7. 絶対に曲げてはいけない設計原則 (CONTRIBUTING.md より)

1. **E2EE Blob を復号しない** — `transport.ex` / `Guild.Process` は
   `payload` を一切解釈・復号しない。
2. **独自暗号を実装しない** — libsignal + OpenMLS (RFC 9420) のみ。
3. **GraphQL を追加しない** — REST + WebSocket (NWP v1) のみ。
4. **公開鍵を Vault に置かない** — 長期秘密鍵のみ Vault、公開鍵は PostgreSQL。
5. **外部依存はすべて `DataSource` behavior 経由** — `transport.ex` から
   `Postgrex` を直接呼ばない。

---

## 8. 次の最重要タスク: nexus-api (Go)

現状の gateway は**骨組み**。`DataSource.Stub` で動いているだけで、本当の
アカウント管理・トークン発行・メッセージ永続化はまだ存在しない。
nexus-api (Go) が以下を担う:

```
POST /v1/auth/register          - アカウント作成 (メールのみ、電話不要)
POST /v1/auth/login             - JWT 発行 (access 15分 + refresh 30日)
POST /v1/auth/refresh           - Token Rotation
GET  /v1/servers                - 参加中サーバー一覧
POST /v1/servers                - サーバー作成
GET  /v1/channels/{id}/messages - 履歴取得 (Layer 3 のみ; Layer1/2 はクライアント保持)
POST /v1/keys/prekeys           - PreKey バンドルアップロード
GET  /v1/keys/{user_id}         - PreKeyBundle 取得
```

### nexus-api 着手時の注意

1. **この gateway と同じ `migrations/` を使うこと**。スキーマを二重に推測しない
   (前任者の最大の反省点)。`golang-migrate` 互換形式なのでそのまま
   `migrate -path migrations -database ... up` で使える。
2. **JWT の `sub` は文字列 UUID 形式**にすること
   (gateway の `Auth.verify_token` がそれを前提にしている)。
3. **Go 側でも UUID 型の扱いに注意** (pgx 等。文字列 ⇄ バイナリ変換の境界を
   一元化する。gateway の `uuid_to_binary/1` と同じ轍を踏まないこと)。
4. `sessions` / `prekeys` テーブルはまだ誰も書き込んでいない。nexus-api が
   初めて使う。

### オーナー (Takorou) に確認すべき未決事項

- nexus-api の Web フレームワーク (Gin / Echo / 標準 net/http — 未指定)
- PostgreSQL ドライバ (pgx 推奨だが未確定)
- nexus-api と nexus-gateway を同一リポジトリにするか別にするか

---

## 9. その他の next steps (優先度順)

1. **nexus-api (Go)** — §8 参照 (最優先)。
2. **E2EE / MLS の実配線** — libsignal (1:1) + OpenMLS (グループ)。
   gateway は MLS_COMMIT / MLS_WELCOME の**配送**のみ担い、暗号処理はしない。
3. **負荷試験** — 1000 並列接続。Guild.Process の単一 GenServer 限界
   (〜10,000人/guild) を超えたら PresenceShard 分割を検討
   (`guild/process.ex` のスケーリング戦略コメント参照)。
4. **NATS subject/payload を nexus-api と整合** — 実 NATS を立てて疎通確認。
5. **observability** — メトリクス / 構造化ログ / トレース。

---

## 10. git 運用メモ (push 前に必読)

`main` は `origin/main` より 2 コミット先行している。push する前に:

```bash
git fetch origin main
git log --oneline origin/main..main     # 先行コミットを確認
# コンフリクトがあれば remote を優先しつつ解決
git push origin main                     # または PR ブランチへ
```

コミットメッセージは Conventional Commits (`feat:` / `fix:` / `test:` / `docs:`)。
PR 前チェックリストは CONTRIBUTING.md の「PR チェックリスト」を参照。

---

頑張ってください。前任の引き継ぎより一段深いところまで来ています。
スキーマは実 DB で検証済み、CI もグリーン確認済み。次は nexus-api です。
