-- mls_groups: MLS (RFC 9420) グループの公開メタ情報。
-- NEXUS_ARCHITECTURE_v0.2.md §7.1 準拠。
--
-- ここに置くのは公開情報のみ (tree_hash, confirmed_transcript等)。
-- 実際のグループ鍵・epoch秘密はクライアントのみが保持する。
-- nexus-gateway の channels.mls_epoch と、このテーブルの current_epoch は
-- 同期させる必要がある (MLS_COMMIT 処理時に両方更新すること。
-- 現状はChannelCacheの更新のみで、このテーブルへの書き込みは
-- nexus-api 側の実装待ち)。

CREATE TABLE mls_groups (
    id             UUID PRIMARY KEY,  -- channels.mls_group_id と一致させる
    channel_id     UUID NOT NULL REFERENCES channels (id) ON DELETE CASCADE,
    current_epoch  BIGINT NOT NULL DEFAULT 0,
    tree_hash      BYTEA,
    confirmed_ts   BYTEA,
    member_count   INT NOT NULL DEFAULT 0,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_mls_groups_channel ON mls_groups (channel_id);
