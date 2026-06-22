# NEXUS PostgreSQL マイグレーション

`golang-migrate` 互換のファイル命名 (`NNNNNN_name.up.sql` / `.down.sql`)。
nexus-api (Go, 未実装) が将来 `golang-migrate` でこれらをそのまま使えるように
この形式で統一している。

## 適用順序

```
000001_create_users.up.sql
000002_create_guilds.up.sql
000003_create_channels.up.sql
000004_create_roles_and_membership.up.sql
000005_create_sessions.up.sql
000006_create_prekeys.up.sql
000007_create_mls_groups.up.sql
```

## 手動適用 (golang-migrate 導入前の暫定手順)

```bash
createdb nexus_dev
for f in migrations/*.up.sql; do
  psql -d nexus_dev -v ON_ERROR_STOP=1 -f "$f"
done
```

## golang-migrate 導入後 (nexus-api 実装時)

```bash
migrate -path migrations -database "postgres://nexus:pass@localhost:5432/nexus_dev?sslmode=disable" up
```

## ★ 重要な設計判断 (必読) ★

### 1. `channels.guild_id` は Layer 1/2 では「合成ルーティングID」

nexus-gateway の既存コードは、チャンネルの種別 (layer) を問わず
必ず `channel_id -> guild_id` が1件取れることを前提にルーティングしている
(`Guild.Process` が「1 guild_id = 1 GenServer」という設計のため)。

本来 Discord 的には guild に属さないはずの以下の layer についても
`guild_id` を NOT NULL のまま持たせている:

- `layer = 1` (Private DM, 1:1) — `guild_id` は会話ごとに発行する合成UUID
- `layer = 2` (Encrypted Group, MLS) — `guild_id` はグループごとに発行する合成UUID

`layer = 3` (Community) のみ、`guild_id` が実際に `guilds.id` を指す。

このため `channels.guild_id` に外部キー制約は付けていない
(layer=1/2 との混在のため意図的)。整合性の保証はアプリケーション層
(nexus-api) の責務とする。

詳細は `000003_create_channels.up.sql` のコメントを参照。

### 2. UUID はバイナリで保存、文字列との変換は アプリケーション層の責務

PostgreSQL の `uuid` 型はバイナリで保存されるが、Postgrex (生のクライアント、
Ecto非使用) はデフォルトで **16バイトの生バイナリ以外を一切受け付けない**。
JWT の `sub` クレーム等から来る文字列形式 UUID
(`"11111111-1111-1111-1111-111111111111"`) をそのまま Postgrex に渡すと
`DBConnection.EncodeError` で例外になる。

→ `lib/nexus_gateway/data_source/postgres.ex` の `uuid_to_binary/1` と
  `uuid_to_string/1` がこの変換を一元的に担う。新しいクエリを追加する際は
  必ずこの変換を経由すること。

(2026-06 実機検証で発見した実バグ。CHANGELOG.md 参照)

### 3. `member_roles` は `guild_members` への複合外部キーを持つ

ロールを付与する前に、必ず `guild_members` に参加レコードが必要
(`FOREIGN KEY (user_id, guild_id) REFERENCES guild_members (user_id, guild_id)`)。
「ギルドに参加していないユーザーにロールだけ付与する」状態を
DBレベルで防止する。

## 動作確認 (このリポジトリで実施済み)

実際に PostgreSQL 16 にこれら7マイグレーションを適用し、
`lib/nexus_gateway/data_source/postgres.ex` の4関数全てを
テストデータに対して実行して結果を確認した
(`test/nexus_gateway/data_source/postgres_test.exs`, `@tag :integration`)。

```bash
# 統合テストの実行 (実DBが必要)
export POSTGRES_HOST=localhost
export POSTGRES_USER=nexus
export POSTGRES_PASSWORD=nexus_dev_pass
export POSTGRES_DB=nexus_dev
mix test --include integration
```
