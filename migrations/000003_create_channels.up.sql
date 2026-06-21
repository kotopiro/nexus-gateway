-- channels: テキスト/ボイス/DM/暗号化グループの全チャンネル種別を1テーブルで管理する。
--
-- ★ 設計判断 (重要、必ず読むこと) ★
--
-- nexus-gateway の既存コード (lib/nexus_gateway/data_source/postgres.ex,
-- channel_cache.ex) は、チャンネルの種別 (layer) を問わず必ず
-- 「channel_id -> guild_id」が1件取れることを前提にルーティングしている
-- (Guild.Process が「1 guild_id = 1 GenServer」というルーティング単位のため)。
--
-- そのため、本来 Discord 的には guild に属さないはずの
--   layer = 1 (Private DM, 1:1)
--   layer = 2 (Encrypted Group, MLS)
-- についても guild_id を NOT NULL のまま持たせる。
--
-- ただし layer = 1/2 の場合、その guild_id は `guilds` テーブルの実在行を
-- 指さない「ルーティング用の合成UUID」であり、意味的には
-- 「この会話/グループの専用ルーティングスコープ」を表すだけ。
-- そのため guild_id への外部キー制約は付けない (FKなし、ただしindexは張る)。
--
-- layer = 3 (Community) の場合のみ、guild_id は実際に guilds.id を指す
-- ことが期待される (アプリケーション層で保証する。DBレベルのFKは
-- layer=1/2との混在のため意図的に付けていない)。
--
-- nexus-api (Go) を実装する際、チャンネル作成時に:
--   layer=3: guild_id = 既存の guilds.id を指定
--   layer=1: guild_id = gen_random_uuid() (1:1の会話ごとに新規発行)
--   layer=2: guild_id = gen_random_uuid() (暗号化グループごとに新規発行)
-- とすること。

CREATE TABLE channels (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    guild_id      UUID NOT NULL,  -- 上記コメント参照。layer次第で意味が異なる
    name          VARCHAR(100) NOT NULL,
    layer         SMALLINT NOT NULL DEFAULT 3,
    channel_type  SMALLINT NOT NULL DEFAULT 0,
    position      INT NOT NULL DEFAULT 0,
    topic         TEXT,
    mls_group_id  UUID,
    mls_epoch     BIGINT NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- layer: 1=PRIVATE_DM(Signal) / 2=ENCRYPTED_GROUP(MLS) / 3=COMMUNITY(平文)
    CONSTRAINT channels_layer_valid CHECK (layer IN (1, 2, 3)),
    -- channel_type: 0=TEXT / 1=VOICE / 2=CATEGORY / 3=STAGE
    CONSTRAINT channels_type_valid CHECK (channel_type IN (0, 1, 2, 3))
);

-- fetch_guild_for_channel / ChannelCache.get_or_fetch が最も叩くクエリパス
CREATE INDEX idx_channels_guild ON channels (guild_id);

-- layer=3 のチャンネルのみ、アプリケーション層で guilds.id との整合性を保証する。
-- (部分インデックスで「実際に guild に属するチャンネル」を検索しやすくする)
CREATE INDEX idx_channels_community_guild ON channels (guild_id) WHERE layer = 3;
