-- sessions: Refresh Token 管理。
-- NEXUS_ARCHITECTURE_v0.2.md §4 (認証・セッション設計) 準拠。
--
-- nexus-gateway はまだこのテーブルを直接読まない
-- (現状は ETS の NexusGateway.Session.Store で RESUME バッファのみ管理)。
-- nexus-api (Go, 未実装) がこのテーブルで Access/Refresh Token の発行・
-- Rotation・デバイス別ログアウトを管理する想定。

CREATE TABLE sessions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    refresh_token_hash  BYTEA NOT NULL UNIQUE,
    device_name         VARCHAR(255),
    platform            VARCHAR(50),
    client_version      VARCHAR(20),
    last_used_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at          TIMESTAMPTZ NOT NULL,
    is_revoked          BOOLEAN NOT NULL DEFAULT FALSE,
    revoked_at          TIMESTAMPTZ
);

CREATE INDEX idx_sessions_user_active ON sessions (user_id) WHERE NOT is_revoked;
