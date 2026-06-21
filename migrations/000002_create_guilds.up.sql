-- guilds: Discordの「サーバー」に相当するコミュニティ単位 (Layer 3)。
-- NEXUS_ARCHITECTURE_v0.2.md §7.3 準拠。

CREATE TABLE guilds (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name          VARCHAR(100) NOT NULL,
    owner_id      UUID REFERENCES users (id) ON DELETE SET NULL,
    member_count  INT NOT NULL DEFAULT 0,
    is_federated  BOOLEAN NOT NULL DEFAULT FALSE,
    home_server   VARCHAR(255),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_guilds_owner ON guilds (owner_id);
