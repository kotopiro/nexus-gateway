-- prekeys: Signal Protocol の PreKey 管理。
-- NEXUS_ARCHITECTURE_v0.2.md §7.1 準拠 (Vault依存を見直した結果、公開鍵はここに置く)。
--
-- 重要: ここに置くのは公開鍵のみ。秘密鍵は絶対にサーバーに送らない
-- (クライアントの OS KeyStore/Keychain のみが保持する)。
--
-- key_type:
--   'signed'   - SignedPreKey (週次ローテーション、署名付き)
--   'one_time' - OneTimePreKey (1回使用、取得時に is_used=true)
--   'pq'       - ML-KEM-768 公開鍵 (PQXDH, Phase 2以降)

CREATE TABLE prekeys (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    key_type    VARCHAR(20) NOT NULL,
    key_id      INT NOT NULL,
    public_key  BYTEA NOT NULL,
    signature   BYTEA,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    used_at     TIMESTAMPTZ,
    is_used     BOOLEAN NOT NULL DEFAULT FALSE,

    CONSTRAINT prekeys_type_valid CHECK (key_type IN ('signed', 'one_time', 'pq')),
    UNIQUE (user_id, key_type, key_id)
);

-- PreKeyBundle取得時 (未使用の鍵を探す) の主経路
CREATE INDEX idx_prekeys_available ON prekeys (user_id, key_type)
    WHERE NOT is_used;
