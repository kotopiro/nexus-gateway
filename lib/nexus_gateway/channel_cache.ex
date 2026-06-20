defmodule NexusGateway.ChannelCache do
  @moduledoc """
  channel_id → guild_id の ETS キャッシュ。

  DataSource (PostgreSQL) への問い合わせ頻度を減らすため、
  Transport から呼ばれる find_guild_for_channel/1 の結果をキャッシュする。

  TTL: 5分。Guild からチャンネルが移動/削除された場合は invalidate/1 で明示的に破棄する。
  """

  use GenServer

  @table      :nexus_channel_cache
  @ttl_ms     5 * 60 * 1_000
  @cleanup_ms 60 * 1_000

  # ─── Public API ─────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "キャッシュから guild_id を取得する。ミスなら :miss を返す (DBへは問い合わせない)。"
  @spec get(String.t()) :: {:ok, String.t()} | :miss
  def get(channel_id) do
    case :ets.lookup(@table, channel_id) do
      [{^channel_id, guild_id, expires_at}] ->
        if monotonic_ms() < expires_at do
          {:ok, guild_id}
        else
          :ets.delete(@table, channel_id)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc "channel_id → guild_id をキャッシュに登録する"
  @spec put(String.t(), String.t()) :: :ok
  def put(channel_id, guild_id) do
    expires_at = monotonic_ms() + @ttl_ms
    :ets.insert(@table, {channel_id, guild_id, expires_at})
    :ok
  end

  @doc "キャッシュエントリを明示的に破棄する (チャンネル削除/移動時)"
  @spec invalidate(String.t()) :: :ok
  def invalidate(channel_id) do
    :ets.delete(@table, channel_id)
    :ok
  end

  @doc "DataSource にフォールバックして取得し、結果をキャッシュする便利関数"
  @spec get_or_fetch(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get_or_fetch(channel_id) do
    case get(channel_id) do
      {:ok, guild_id} ->
        {:ok, guild_id}

      :miss ->
        case NexusGateway.DataSource.fetch_guild_for_channel(channel_id) do
          {:ok, guild_id} ->
            put(channel_id, guild_id)
            {:ok, guild_id}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # ─── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(_) do
    :ets.new(@table, [
      :set, :public, :named_table,
      read_concurrency:  true,
      write_concurrency: true,
    ])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = monotonic_ms()

    :ets.tab2list(@table)
    |> Enum.each(fn {channel_id, _guild_id, expires_at} ->
      if expires_at < now, do: :ets.delete(@table, channel_id)
    end)

    schedule_cleanup()
    {:noreply, state}
  end

  # ─── Private ────────────────────────────────────────────────────────

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_ms)
  end
end
