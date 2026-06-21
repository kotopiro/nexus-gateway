defmodule NexusGateway.Guild.Process do
  @moduledoc """
  1 Guild (サーバー) につき 1 つ起動する GenServer。

  責務:
    - メンバーの接続/切断管理
    - チャンネルへのイベント fanout
    - Presence 状態の管理
    - Typing Indicator (TTL 3秒)
    - Voice 状態の管理
    - E2EE/MLS イベントのルーティング

  スケーリング戦略 (将来):
    1〜10,000人 → このプロセス 1 つで対応
    10,000人〜  → GuildSupervisor + PresenceShard に分割
  """

  use GenServer
  require Logger

  alias NexusGateway.NWP.Frame
  alias NexusGateway.DataSource

  @typing_ttl_ms 3_000

  # GUILD_MEMBERS_CHUNK 1 件あたりの最大メンバー数 (Discord 互換)
  @members_chunk_size 1_000

  # ─── Public API ─────────────────────────────────────────────────────

  def start_link(guild_id) do
    GenServer.start_link(__MODULE__, guild_id, name: via(guild_id))
  end

  def join(guild_id, user_id, conn_pid) do
    GenServer.cast(via(guild_id), {:join, user_id, conn_pid})
  end

  def leave(guild_id, user_id, conn_pid) do
    GenServer.cast(via(guild_id), {:leave, user_id, conn_pid})
  end

  def dispatch(guild_id, channel_id, event_type, data) do
    GenServer.cast(via(guild_id), {:dispatch, channel_id, event_type, data})
  end

  def broadcast(guild_id, event_type, data) do
    GenServer.cast(via(guild_id), {:broadcast, event_type, data})
  end

  def update_presence(guild_id, user_id, presence) do
    GenServer.cast(via(guild_id), {:presence_update, user_id, presence})
  end

  def typing_start(guild_id, channel_id, user_id) do
    GenServer.cast(via(guild_id), {:typing_start, channel_id, user_id})
  end

  @doc """
  REQUEST_MEMBERS (op:11) への応答。
  要求元の接続プロセス (reply_pid) に GUILD_MEMBERS_CHUNK を分割配信する。

  opts:
    "query" - user_id の前方一致フィルタ (任意, 空文字なら全件)
    "limit" - 返す最大件数 (任意)
  """
  def request_members(guild_id, reply_pid, opts \\ %{}) do
    GenServer.cast(via(guild_id), {:request_members, reply_pid, opts})
  end

  @doc "デバッグ・テスト用: 現在の状態を返す"
  def get_state(guild_id) do
    GenServer.call(via(guild_id), :get_state)
  end

  # ─── GenServer Callbacks ────────────────────────────────────────────

  @impl true
  def init(guild_id) do
    Logger.info("[Guild:#{guild_id}] Process started")

    {:ok,
     %{
       guild_id: guild_id,
       # user_id => [conn_pid, ...]  (複数デバイス対応)
       connections: %{},
       # channel_id => [user_id, ...]  (チャンネル購読者)
       subscriptions: %{},
       # user_id => presence_map
       presences: %{},
       # channel_id => [voice_state_map, ...]
       voice_states: %{},
       # {channel_id, user_id} => timer_ref
       typing_timers: %{}
     }}
  end

  @impl true
  def handle_cast({:join, user_id, conn_pid}, state) do
    Process.monitor(conn_pid)

    new_conns =
      Map.update(
        state.connections,
        user_id,
        [conn_pid],
        &[conn_pid | &1]
      )

    new_state = %{state | connections: new_conns}

    # 新規接続を含めた状態で fanout する。
    # (旧 state で fanout すると join した本人にオンライン通知が届かない)
    fanout(
      new_state,
      Frame.event("PRESENCE_UPDATE", %{
        "user_id" => user_id,
        "status" => "online"
      })
    )

    Logger.debug("[Guild:#{state.guild_id}] #{user_id} joined")
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:leave, user_id, conn_pid}, state) do
    new_conns =
      case Map.get(state.connections, user_id) do
        nil ->
          state.connections

        pids ->
          remaining = List.delete(pids, conn_pid)

          if remaining == [],
            do: Map.delete(state.connections, user_id),
            else: Map.put(state.connections, user_id, remaining)
      end

    if not Map.has_key?(new_conns, user_id) do
      # 退出前の state で fanout する。
      # new_conns では退出者の conn_pid が既に除かれているため、
      # 退出者本人にオフライン通知を届けるには旧 state を使う必要がある。
      # (残存メンバーも旧 state に含まれるので全員に届く)
      fanout(
        state,
        Frame.event("PRESENCE_UPDATE", %{
          "user_id" => user_id,
          "status" => "offline"
        })
      )
    end

    Logger.debug("[Guild:#{state.guild_id}] #{user_id} left")
    {:noreply, %{state | connections: new_conns}}
  end

  @impl true
  def handle_cast({:dispatch, channel_id, event_type, data}, state) do
    subscribers = Map.get(state.subscriptions, channel_id, [])
    event = Frame.event(event_type, data)

    subscribers
    |> Enum.flat_map(&Map.get(state.connections, &1, []))
    |> Enum.each(&send(&1, {:dispatch, event}))

    {:noreply, state}
  end

  @impl true
  def handle_cast({:broadcast, event_type, data}, state) do
    fanout(state, Frame.event(event_type, data))
    {:noreply, state}
  end

  @impl true
  def handle_cast({:presence_update, user_id, presence}, state) do
    new_presences = Map.put(state.presences, user_id, presence)

    fanout(
      state,
      Frame.event(
        "PRESENCE_UPDATE",
        Map.put(presence, "user_id", user_id)
      )
    )

    {:noreply, %{state | presences: new_presences}}
  end

  @impl true
  def handle_cast({:typing_start, channel_id, user_id}, state) do
    key = {channel_id, user_id}

    # 既存タイマーをキャンセル (連打対応)
    if ref = Map.get(state.typing_timers, key) do
      Process.cancel_timer(ref)
    end

    # 自分以外のチャンネル購読者に送信
    subs = Map.get(state.subscriptions, channel_id, []) |> List.delete(user_id)

    event =
      Frame.event("TYPING_START", %{
        "user_id" => user_id,
        "channel_id" => channel_id,
        "timestamp" => :os.system_time(:millisecond)
      })

    subs
    |> Enum.flat_map(&Map.get(state.connections, &1, []))
    |> Enum.each(&send(&1, {:dispatch, event}))

    # 3秒後に自動終了
    ref = Process.send_after(self(), {:typing_stop, key}, @typing_ttl_ms)
    {:noreply, %{state | typing_timers: Map.put(state.typing_timers, key, ref)}}
  end

  @impl true
  def handle_cast({:request_members, reply_pid, opts}, state) do
    query = Map.get(opts, "query", "")
    limit = Map.get(opts, "limit")

    case DataSource.fetch_guild_members(state.guild_id) do
      {:ok, members} ->
        members
        |> filter_members(query)
        |> maybe_limit(limit)
        |> annotate_presence(state)
        |> send_member_chunks(reply_pid, state.guild_id)

      {:error, reason} ->
        Logger.warning("[Guild:#{state.guild_id}] request_members failed: #{inspect(reason)}")

        # 失敗時も空の終端チャンク 1 件を送り、クライアントを待たせない
        send_member_chunks([], reply_pid, state.guild_id)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, dead_pid, reason}, state) do
    Logger.debug("[Guild:#{state.guild_id}] Connection DOWN: #{inspect(reason)}")

    {new_conns, offline_users} =
      Enum.reduce(state.connections, {%{}, []}, fn {uid, pids}, {acc, offline} ->
        case List.delete(pids, dead_pid) do
          [] -> {acc, [uid | offline]}
          rest -> {Map.put(acc, uid, rest), offline}
        end
      end)

    new_state = %{state | connections: new_conns}

    Enum.each(offline_users, fn uid ->
      fanout(
        new_state,
        Frame.event("PRESENCE_UPDATE", %{
          "user_id" => uid,
          "status" => "offline"
        })
      )
    end)

    {:noreply, new_state}
  end

  def handle_info({:typing_stop, key}, state) do
    {:noreply, %{state | typing_timers: Map.delete(state.typing_timers, key)}}
  end

  # ─── Private ────────────────────────────────────────────────────────

  defp via(guild_id) do
    {:via, Registry, {NexusGateway.Registry, {:guild, guild_id}}}
  end

  defp fanout(state, event_map) do
    state.connections
    |> Map.values()
    |> List.flatten()
    |> Enum.each(&send(&1, {:dispatch, event_map}))
  end

  # query が空文字なら全件、それ以外は user_id の前方一致でフィルタする。
  defp filter_members(members, "") do
    members
  end

  defp filter_members(members, query) when is_binary(query) do
    Enum.filter(members, fn m ->
      String.starts_with?(Map.get(m, "user_id", ""), query)
    end)
  end

  # limit が nil なら全件、指定されていれば先頭から limit 件に絞る。
  defp maybe_limit(members, nil), do: members

  defp maybe_limit(members, limit) when is_integer(limit) and limit >= 0 do
    Enum.take(members, limit)
  end

  defp maybe_limit(members, _invalid_limit), do: members

  # DataSource から取得した静的メンバー情報に、GuildProcess が保持する
  # 現在のオンライン状態 (Presence) を付与する。
  # E2EE 原則: ここで付与するのは online/offline の状態のみ。
  # activities 等の詳細な Presence (Layer 3 限定) は含めない
  # (GUILD_MEMBERS_CHUNK は Layer に関わらず全メンバーへの応答のため)。
  defp annotate_presence(members, state) do
    Enum.map(members, fn member ->
      user_id = Map.get(member, "user_id")
      status = if Map.has_key?(state.connections, user_id), do: "online", else: "offline"
      Map.put(member, "status", status)
    end)
  end

  # GUILD_MEMBERS_CHUNK イベントを @members_chunk_size 件ごとに分割して
  # 要求元 (reply_pid) にのみ送信する。Guild 全体への fanout はしない。
  #
  # メンバーが 0 件の場合でも、空配列を持つチャンクを 1 件だけ送る。
  # これによりクライアントは「応答が来た (待ち状態を解除してよい)」ことを
  # 確実に検知できる (Discord の GUILD_MEMBERS_CHUNK と同様の終端保証)。
  defp send_member_chunks([], reply_pid, guild_id) do
    send_chunk(reply_pid, guild_id, [], 0, 1)
  end

  defp send_member_chunks(members, reply_pid, guild_id) do
    chunks = Enum.chunk_every(members, @members_chunk_size)
    total = length(chunks)

    chunks
    |> Enum.with_index()
    |> Enum.each(fn {chunk, index} ->
      send_chunk(reply_pid, guild_id, chunk, index, total)
    end)
  end

  defp send_chunk(reply_pid, guild_id, members, chunk_index, chunk_count) do
    event =
      Frame.event("GUILD_MEMBERS_CHUNK", %{
        "guild_id" => guild_id,
        "members" => members,
        "chunk_index" => chunk_index,
        "chunk_count" => chunk_count
      })

    send(reply_pid, {:dispatch, event})
  end
end
