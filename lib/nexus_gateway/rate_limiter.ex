defmodule NexusGateway.RateLimiter do
  @moduledoc """
  ETS ベースの sliding window レート制限。

  本番では Redis に差し替える想定 (複数ノードでの一貫性が必要なため)。
  プロトタイプではノード単体での動作を前提に ETS で実装する。

  ルール (NEXUS_GATEWAY_NWP_v1.md §13 準拠):
    全 opcode:        120件/分  per connection
    TYPING_START:     1件/3秒  per (user_id, channel_id)
    E2EE_ENVELOPE:    20件/秒 (burst) / 5件/秒 (sustained) per connection
  """

  use GenServer

  @table :nexus_rate_limits
  @cleanup_ms 30 * 1_000

  @global_limit 120
  @global_window_ms 60_000

  @typing_limit 1
  @typing_window_ms 3_000

  @e2ee_burst_limit 20
  @e2ee_burst_window_ms 1_000
  @e2ee_sustained_limit 5
  @e2ee_sustained_window_ms 1_000

  # ─── Public API ─────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  接続全体のレート制限をチェックする (全 opcode 共通: 120件/分)。
  conn_id には接続プロセスの pid を文字列化したものか session_id を渡す。
  """
  @spec check_global(String.t()) :: :ok | {:error, :rate_limited}
  def check_global(conn_id) do
    check(:global, conn_id, @global_limit, @global_window_ms)
  end

  @doc "TYPING_START のレート制限 (同一 user+channel で 1件/3秒)"
  @spec check_typing(String.t(), String.t()) :: :ok | {:error, :rate_limited}
  def check_typing(user_id, channel_id) do
    key = "#{user_id}:#{channel_id}"
    check(:typing, key, @typing_limit, @typing_window_ms)
  end

  @doc "E2EE_ENVELOPE のレート制限 (burst + sustained の両方を満たす必要がある)"
  @spec check_e2ee(String.t()) :: :ok | {:error, :rate_limited}
  def check_e2ee(conn_id) do
    with :ok <- check(:e2ee_burst, conn_id, @e2ee_burst_limit, @e2ee_burst_window_ms),
         :ok <- check(:e2ee_sustained, conn_id, @e2ee_sustained_limit, @e2ee_sustained_window_ms) do
      :ok
    end
  end

  # ─── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(_) do
    # :duplicate_bag を使う点が重要。
    # :bag は「同一の完全なタプル」を重複排除するため、{key, ts} で ts (ミリ秒) が
    # 同じ値だと複数回の挿入が 1 件に潰れてしまい、レート制限が正しく機能しない
    # (同一ミリ秒内の連続リクエストがカウントされない)。
    # :duplicate_bag なら同一タプルでも全て保持されるため、正確にカウントできる。
    :ets.new(@table, [
      :duplicate_bag,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = monotonic_ms()

    # 全エントリを走査して古いタイムスタンプを削除 (bag なので個別削除が必要)
    :ets.tab2list(@table)
    |> Enum.each(fn {key, ts} = entry ->
      window = window_for(key)
      if now - ts > window, do: :ets.delete_object(@table, entry)
    end)

    schedule_cleanup()
    {:noreply, state}
  end

  # ─── Private ────────────────────────────────────────────────────────

  defp check(scope, id, limit, window_ms) do
    key = {scope, id}
    now = monotonic_ms()

    :ets.insert(@table, {key, now})

    count =
      :ets.lookup(@table, key)
      |> Enum.count(fn {_key, ts} -> now - ts <= window_ms end)

    if count > limit do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  # cleanup 時にキーごとのウィンドウ幅を判定する (key は {scope, id} 形式)
  defp window_for({:global, _}), do: @global_window_ms
  defp window_for({:typing, _}), do: @typing_window_ms
  defp window_for({:e2ee_burst, _}), do: @e2ee_burst_window_ms
  defp window_for({:e2ee_sustained, _}), do: @e2ee_sustained_window_ms
  defp window_for(_), do: @global_window_ms

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_ms)
  end
end
