-- users: アカウント本体。
-- NEXUS_ARCHITECTURE_v0.2.md §7.3 準拠。
--
-- 設計上の注意:
--   email はそのまま平文保存しない。
--   email_hash    = HMAC-SHA256(email, pepper) でユニーク制約をかける検索用ハッシュ
--   email_ciphertext = AES-256-GCM で暗号化した実体 (復号は nexus-api 側のみ)
--   pepper / 暗号鍵は環境変数 or Vault で管理し、このDBには置かない。
--
--   identity_key_pub / identity_key_sig は Signal Protocol の Identity Key。
--   秘密鍵は絶対にこのテーブルに置かない (クライアントのみ保持)。

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username          VARCHAR(32) UNIQUE NOT NULL,
    email_hash        BYTEA UNIQUE,
    email_ciphertext  BYTEA,
    password_hash     VARCHAR(255),
    totp_secret_enc   BYTEA,
    identity_key_pub  BYTEA,
    identity_key_sig  BYTEA,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at      TIMESTAMPTZ,

    CONSTRAINT username_format CHECK (username ~ '^[a-z0-9_.-]{3,32}$')
);

CREATE INDEX idx_users_last_seen ON users (last_seen_at);
