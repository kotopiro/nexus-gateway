defmodule NexusGateway.Session.Store do
  @moduledoc """
  セッション管理 (ETS ベース)。

  プロトタイプ: インメモリ ETS。
  本番移行時: Redis (Redix) に差し替え。
  インターフェースは変えない。

  セッション = 認証済み WebSocket 接続の状態。
  RESUME のためにイベントをリングバッファで保持する。
  """

  use GenServer

  @table         :nexus_sessions
  @max_events    5_000            # RESUME バッファ上限
  @ttl_ms        5 * 60 * 1_000  # 5分 (切断後 RESUME 可能期間)
  @cleanup_ms    60 * 1_000       # 1分ごとにクリーンアップ

  # ─── Public API ─────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "新しいセッションを作成して session_id を返す"
  @spec create(String.t(), pid()) :: String.t()
  def create(user_id, conn_pid) do
    session_id = generate_id()
    session = %{
      user_id:    user_id,
      conn_pid:   conn_pid,
      created_at: monotonic_ms(),
      events:     [],
    }
    :ets.insert(@table, {session_id, session})
    session_id
  end

  @doc "セッションを取得"
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] -> {:ok, session}
      []                       -> {:error, :not_found}
    end
  end

  @doc "セッションを削除"
  @spec delete(String.t() | nil) :: :ok
  def delete(nil), do: :ok
  def delete(session_id) do
    :ets.delete(@table, session_id)
    :ok
  end

  @doc "RESUME 用イベントをバッファに積む"
  @spec buffer_event(String.t(), map()) :: :ok
  def buffer_event(session_id, event) do
    GenServer.cast(__MODULE__, {:buffer, session_id, event})
  end

  @doc "seq 以降のバッファ済みイベントを返す (古い順)"
  @spec get_events_since(String.t(), non_neg_integer()) :: [map()]
  def get_events_since(session_id, seq) do
    case get(session_id) do
      {:ok, %{events: events}} ->
        events
        |> Enum.filter(fn e -> (e[:s] || 0) > seq end)
        |> Enum.sort_by(fn e -> e[:s] || 0 end)

      {:error, _} ->
        []
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
  def handle_cast({:buffer, session_id, event}, state) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, session}] ->
        # 新しいイベントを先頭に積み、上限で切る
        new_events = [event | session.events] |> Enum.take(@max_events)
        :ets.insert(@table, {session_id, %{session | events: new_events}})
      [] ->
        :ok
    end
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = monotonic_ms() - @ttl_ms

    :ets.tab2list(@table)
    |> Enum.each(fn {id, session} ->
      if session.created_at < cutoff, do: :ets.delete(@table, id)
    end)

    schedule_cleanup()
    {:noreply, state}
  end

  # ─── Private ────────────────────────────────────────────────────────

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_ms)
  end
end
