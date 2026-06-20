# :integration タグ付きテストは実際の PostgreSQL/NATS 接続が必要なため
# 通常の `mix test` からは除外する。
# 実行する場合: `mix test --include integration`
ExUnit.start(exclude: [:integration])
