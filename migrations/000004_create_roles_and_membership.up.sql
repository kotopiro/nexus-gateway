-- roles / guild_members / member_roles
--
-- これら3テーブルは Discord ライクな「ロールベース権限」を実現する。
-- nexus-gateway の fetch_channel_permissions/2 が叩く実体は member_roles + roles。
--
-- guild_members は「誰がどの guild に参加しているか」(fetch_guild_ids が叩く)。
-- layer=1/2 チャンネル (DM/暗号化グループ) の guild_id も、channels テーブルの
-- 設計判断と同様に「ルーティング用合成guild_id」として guild_members に
-- 参加者を記録する。これにより fetch_guild_ids/1 は DM/暗号化グループも含めて
-- 一貫したクエリで全参加チャンネルを返せる。

CREATE TABLE roles (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    guild_id    UUID NOT NULL,
    name        VARCHAR(100) NOT NULL,
    color       INT NOT NULL DEFAULT 0,
    position    INT NOT NULL DEFAULT 0,
    -- permissions: NexusGateway.Permissions のビットフラグと対応 (BIGINT)
    permissions BIGINT NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_roles_guild ON roles (guild_id);

CREATE TABLE guild_members (
    user_id    UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    guild_id   UUID NOT NULL,
    joined_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    nickname   VARCHAR(32),

    PRIMARY KEY (user_id, guild_id)
);

-- fetch_guild_ids/1 ( WHERE user_id = $1 ) の主経路
CREATE INDEX idx_guild_members_user ON guild_members (user_id);
-- fetch_guild_members/1 ( WHERE guild_id = $1 ) の主経路
CREATE INDEX idx_guild_members_guild ON guild_members (guild_id);

CREATE TABLE member_roles (
    user_id   UUID NOT NULL,
    guild_id  UUID NOT NULL,
    role_id   UUID NOT NULL REFERENCES roles (id) ON DELETE CASCADE,

    PRIMARY KEY (user_id, guild_id, role_id),
    FOREIGN KEY (user_id, guild_id) REFERENCES guild_members (user_id, guild_id) ON DELETE CASCADE
);

-- fetch_channel_permissions/2 の JOIN 経路 (user_id, guild_id) の複合検索
CREATE INDEX idx_member_roles_user_guild ON member_roles (user_id, guild_id);
