defmodule NexusGateway.Transport do
  @moduledoc """
  NWP v1 WebSocket Transport (Phoenix.Socket.Transport)

  接続ライフサイクル:
    1. connect/1    → 接続受付・初期状態作成
    2. init/1       → HELLO 送信スケジュール
    3. handle_in/2  → クライアントからのフレーム処理
    4. handle_info  → 内部メッセージ (HELLO送信, dispatch, heartbeat check)
    5. terminate/2  → 切断クリーンアップ

  E2EE に関する原則:
    このモジュールは E2EE Blob の内容を一切復号しない。
    op:13 / op:14 の payload フィールドは bytes のまま転送する。

  外部依存の抽象化:
    DataSource          guild_ids / channel→guild / 権限 の取得元 (Postgres or Stub)
    ChannelCache         channel_id → guild_id のキャッシュ (TTL 5分)
    Permissions          権限ビットフラグ判定
    RateLimiter          opcode 別レート制限
    ConnectionRegistry   user_id → conn_pid (MLS Welcome 個別配送等)
    NATS.Publisher       nexus-api / nexus-media への発行 (no-op フォールバック付き)
  """

  @behaviour Phoenix.Socket.Transport

  require Logger

  # Phoenix.Endpoint の socket/3 は内部で module.child_spec/1 を呼ぶ。
  # Raw Transport は Cowboy が接続ごとにプロセスを作るため、
  # Supervision Tree への登録は不要。:ignore を返すことで Supervisor に無視させる。
  @doc false
  @impl true
  def child_spec(_opts), do: :ignore

  alias NexusGateway.{Auth, Session, DataSource, ChannelCache, Permissions, RateLimiter}
  alias NexusGateway.ConnectionRegistry
  alias NexusGateway.NWP.{Frame, Opcodes}
  alias NexusGateway.Guild
  alias NexusGateway.NATS.Publisher

  # Heartbeat: 45秒 ± 最大5秒のジッター
  @hb_base_ms 45_000
  @hb_jitter 5_000

  # ─── Transport Callbacks ────────────────────────────────────────────

  @impl true
  def connect(%{params: params}) do
    interval = @hb_base_ms - :rand.uniform(@hb_jitter)

    {:ok,
     %{
       authenticated: false,
       user_id: nil,
       session_id: nil,
       seq: 0,
       heartbeat_interval: interval,
       last_heartbeat_ms: monotonic_ms(),
       intents: 0,
       guild_ids: [],
       encoding: Map.get(params, "encoding", "msgpack")
     }}
  end

  @impl true
  def init(state) do
    # init/1 では直接 push できないので handle_info 経由
    send(self(), :send_hello)
    schedule_hb_check(state.heartbeat_interval * 2)
    {:ok, state}
  end

  @impl true
  def handle_in({payload, opcode: :binary}, state) do
    case Frame.decode(payload) do
      {:ok, frame} ->
        route(frame, state)

      {:error, reason} ->
        Logger.warning("[Transport] Decode error: #{inspect(reason)}")
        err = Frame.error_event(4002, "Decode error")
        {:push, {:binary, err}, state}
    end
  end

  def handle_in({_payload, opcode: :text}, state) do
    # テキストフレームは受け付けない
    err = Frame.error_event(4002, "Text frames not supported. Use binary/msgpack.")
    {:push, {:binary, err}, state}
  end

  # ─── Internal Messages ───────────────────────────────────────────────

  @impl true
  def handle_info(:send_hello, state) do
    hello =
      Frame.encode(%{
        op: Opcodes.hello(),
        d: %{"heartbeat_interval" => state.heartbeat_interval},
        s: nil,
        t: nil
      })

    {:push, {:binary, hello}, state}
  end

  def handle_info(:check_heartbeat, state) do
    elapsed = monotonic_ms() - state.last_heartbeat_ms
    limit = state.heartbeat_interval * 2

    if elapsed > limit do
      Logger.warning("[Transport] Heartbeat timeout: #{state.user_id}")
      {:stop, :heartbeat_timeout, state}
    else
      schedule_hb_check(state.heartbeat_interval)
      {:ok, state}
    end
  end

  # GuildProcess からの dispatch イベント
  def handle_info({:dispatch, event_map}, state) do
    seq = state.seq + 1
    # シーケンス番号を付与してエンコード
    frame = Frame.encode(Map.put(event_map, :s, seq))
    # RESUME バッファにも積む
    Session.Store.buffer_event(state.session_id, Map.put(event_map, :s, seq))
    {:push, {:binary, frame}, %{state | seq: seq}}
  end

  # RESUME 時の missed events 再送 (再帰的に自分宛に送る)
  def handle_info({:replay, []}, state) do
    {:ok, state}
  end

  def handle_info({:replay, [event | rest]}, state) do
    send(self(), {:replay, rest})
    seq = state.seq + 1
    frame = Frame.encode(Map.put(event, :s, seq))
    {:push, {:binary, frame}, %{state | seq: seq}}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[Transport] Disconnected: #{state.user_id} / #{inspect(reason)}")

    if state.user_id do
      Enum.each(state.guild_ids, fn gid ->
        Guild.Process.leave(gid, state.user_id, self())
      end)

      ConnectionRegistry.unregister(state.user_id)
      Session.Store.delete(state.session_id)
    end

    :ok
  end

  # ─── Frame Router ────────────────────────────────────────────────────

  defp route(%{op: op} = frame, state) do
    cond do
      # 未認証 + 認証が必要な opcode → 強制切断
      # (Opcodes.* は関数呼び出しのためガード節では使えない。cond の body で判定する)
      not state.authenticated and op != Opcodes.identify() and op != Opcodes.resume() ->
        Logger.warning("[Transport] Unauthenticated opcode #{op}")
        {:stop, :not_authenticated, state}

      # 認証済み接続には全 opcode 共通のグローバルレート制限をかける
      # (IDENTIFY/RESUME は未認証なので対象外)
      state.authenticated ->
        case RateLimiter.check_global(conn_id(state)) do
          :ok ->
            dispatch_opcode(op, frame, state)

          {:error, :rate_limited} ->
            err = Frame.error_event(4008, "Rate limited")
            {:push, {:binary, err}, state}
        end

      true ->
        dispatch_opcode(op, frame, state)
    end
  end

  defp dispatch_opcode(op, frame, state) do
    cond do
      op == Opcodes.heartbeat() ->
        on_heartbeat(state)

      op == Opcodes.identify() ->
        on_identify(frame.d, state)

      op == Opcodes.resume() ->
        on_resume(frame.d, state)

      op == Opcodes.presence_update() ->
        on_presence_update(frame.d, state)

      op == Opcodes.typing_start() ->
        on_typing_start(frame.d, state)

      op == Opcodes.voice_state_update() ->
        on_voice_state_update(frame.d, state)

      op == Opcodes.request_members() ->
        on_request_members(frame.d, state)

      op == Opcodes.e2ee_envelope() ->
        on_e2ee_envelope(frame.d, state)

      op == Opcodes.mls_commit() ->
        on_mls_commit(frame.d, state)

      true ->
        Logger.warning("[Transport] Unknown opcode: #{op}")
        err = Frame.error_event(4001, "Unknown opcode: #{op}")
        {:push, {:binary, err}, state}
    end
  end

  # ─── Opcode Handlers ─────────────────────────────────────────────────

  defp on_heartbeat(state) do
    ack = Frame.encode(%{op: Opcodes.heartbeat_ack(), d: nil, s: nil, t: nil})
    {:push, {:binary, ack}, %{state | last_heartbeat_ms: monotonic_ms()}}
  end

  defp on_identify(_data, %{authenticated: true} = state) do
    # 二重 IDENTIFY → invalid_session を push して続行
    frame = Frame.encode(%{op: Opcodes.invalid_session(), d: false, s: nil, t: nil})
    {:push, {:binary, frame}, state}
  end

  defp on_identify(nil, state) do
    {:stop, :missing_identify_data, state}
  end

  defp on_identify(data, state) do
    token = data["token"]
    intents = data["intents"] || 0

    with {:ok, claims} <- Auth.verify_token(token),
         user_id = claims["sub"],
         {:ok, guild_ids} <- DataSource.fetch_guild_ids(user_id),
         session_id = Session.Store.create(user_id, self()) do
      ConnectionRegistry.register(user_id)

      Enum.each(guild_ids, fn gid ->
        Guild.Supervisor.ensure_started(gid)
        Guild.Process.join(gid, user_id, self())
      end)

      ready = build_ready(user_id, claims, guild_ids, session_id)

      new_state = %{
        state
        | authenticated: true,
          user_id: user_id,
          session_id: session_id,
          intents: intents,
          guild_ids: guild_ids
      }

      Logger.info("[Transport] IDENTIFY ok: #{user_id}")
      {:push, {:binary, ready}, new_state}
    else
      {:error, :token_expired} ->
        _frame = Frame.encode(%{op: Opcodes.invalid_session(), d: false, s: nil, t: nil})
        {:stop, :token_expired, state}

      {:error, reason} ->
        Logger.warning("[Transport] IDENTIFY failed: #{inspect(reason)}")
        {:stop, :auth_failed, state}
    end
  end

  defp on_resume(nil, state), do: {:stop, :missing_resume_data, state}

  defp on_resume(data, state) do
    session_id = data["session_id"]
    token = data["token"]
    last_seq = data["seq"] || 0

    with {:ok, claims} <- Auth.verify_token(token),
         {:ok, _session} <- Session.Store.get(session_id),
         user_id = claims["sub"],
         {:ok, guild_ids} <- DataSource.fetch_guild_ids(user_id) do
      ConnectionRegistry.register(user_id)

      Enum.each(guild_ids, fn gid ->
        Guild.Supervisor.ensure_started(gid)
        Guild.Process.join(gid, user_id, self())
      end)

      missed = Session.Store.get_events_since(session_id, last_seq)
      send(self(), {:replay, missed})

      resumed = Frame.encode(%{op: Opcodes.resumed(), d: nil, s: last_seq, t: nil})

      new_state = %{
        state
        | authenticated: true,
          user_id: user_id,
          session_id: session_id,
          guild_ids: guild_ids,
          seq: last_seq
      }

      Logger.info("[Transport] RESUME ok: #{user_id}, replaying #{length(missed)} events")
      {:push, {:binary, resumed}, new_state}
    else
      {:error, :not_found} ->
        frame = Frame.encode(%{op: Opcodes.invalid_session(), d: false, s: nil, t: nil})
        {:push, {:binary, frame}, state}

      {:error, _} ->
        frame = Frame.encode(%{op: Opcodes.invalid_session(), d: false, s: nil, t: nil})
        {:push, {:binary, frame}, state}
    end
  end

  defp on_presence_update(data, state) do
    Enum.each(state.guild_ids, &Guild.Process.update_presence(&1, state.user_id, data))
    {:ok, state}
  end

  defp on_typing_start(data, state) do
    channel_id = data["channel_id"]

    with :ok <- RateLimiter.check_typing(state.user_id, channel_id),
         true <- Permissions.can_send_typing?(state.user_id, channel_id),
         {:ok, guild_id} <- ChannelCache.get_or_fetch(channel_id) do
      Guild.Process.typing_start(guild_id, channel_id, state.user_id)
      {:ok, state}
    else
      {:error, :rate_limited} ->
        # 静かに無視 (typing は頻繁なので毎回エラーを返さない)
        {:ok, state}

      false ->
        err = Frame.error_event(50013, "Missing permission: send_typing")
        {:push, {:binary, err}, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  defp on_voice_state_update(data, state) do
    guild_id = data["guild_id"]
    channel_id = data["channel_id"]

    if guild_id && Enum.member?(state.guild_ids, guild_id) do
      Guild.Process.broadcast(guild_id, "VOICE_STATE_UPDATE", %{
        "user_id" => state.user_id,
        "guild_id" => guild_id,
        "channel_id" => channel_id,
        "self_mute" => data["self_mute"] || false,
        "self_deaf" => data["self_deaf"] || false,
        "self_video" => data["self_video"] || false
      })

      if channel_id do
        Publisher.publish_voice_join(%{
          "user_id" => state.user_id,
          "guild_id" => guild_id,
          "channel_id" => channel_id
        })
      else
        Publisher.publish_voice_leave(%{
          "user_id" => state.user_id,
          "guild_id" => guild_id
        })
      end
    end

    {:ok, state}
  end

  defp on_request_members(data, state) do
    guild_id = data["guild_id"]

    if guild_id && Enum.member?(state.guild_ids, guild_id) do
      opts = %{
        "query" => data["query"] || "",
        "limit" => data["limit"]
      }

      # 応答は要求元 (self()) にのみ返す。Guild 全体への broadcast はしない。
      Guild.Process.request_members(guild_id, self(), opts)
    else
      Logger.warning(
        "[Transport] REQUEST_MEMBERS: #{state.user_id} is not a member of #{inspect(guild_id)}"
      )
    end

    {:ok, state}
  end

  defp on_e2ee_envelope(data, state) do
    channel_id = data["channel_id"]

    with :ok <- RateLimiter.check_e2ee(conn_id(state)),
         true <- Permissions.can_send_messages?(state.user_id, channel_id),
         {:ok, guild_id} <- ChannelCache.get_or_fetch(channel_id) do
      payload = %{
        "sender_id" => state.user_id,
        "channel_id" => channel_id,
        # bytes のまま (復号しない)
        "payload" => data["payload"],
        "payload_type" => data["payload_type"],
        "message_id" => data["message_id"],
        "timestamp" => :os.system_time(:millisecond)
      }

      # nexus-api に永続化を依頼 (NATS, 未接続なら no-op)
      Publisher.publish_e2ee_create(Map.put(payload, "recipient_ids", data["recipient_ids"]))

      # プロトタイプ: gateway 内でも直接 fanout する
      # (本番では nexus-api からの dispatch.channel.* を Consumer が受けて fanout する設計。
      #  二重配送を避けるため、本番投入時はこちらの直接 dispatch を削除すること)
      Guild.Process.dispatch(guild_id, channel_id, "E2EE_MESSAGE", payload)

      {:ok, state}
    else
      {:error, :rate_limited} ->
        err = Frame.error_event(4008, "Rate limited: E2EE_ENVELOPE")
        {:push, {:binary, err}, state}

      false ->
        err = Frame.error_event(50013, "Missing permission: send_messages")
        {:push, {:binary, err}, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  defp on_mls_commit(data, state) do
    channel_id = data["channel_id"]

    case ChannelCache.get_or_fetch(channel_id) do
      {:error, _} ->
        {:ok, state}

      {:ok, guild_id} ->
        Publisher.publish_mls_commit(data)

        Guild.Process.dispatch(guild_id, channel_id, "MLS_COMMIT", data)

        # welcomes: recipient_id ごとに個別配送 (guild broadcast は使わない)
        welcomes = data["welcomes"] || []

        Enum.each(welcomes, fn welcome ->
          recipient_id = welcome["recipient_id"]

          event = %{
            op: Opcodes.mls_welcome(),
            d: %{
              "group_id" => data["group_id"],
              "welcome_msg" => welcome["welcome_msg"]
            },
            s: nil,
            t: nil
          }

          case ConnectionRegistry.lookup(recipient_id) do
            [] ->
              Logger.warning("[Transport] MLS_WELCOME: #{recipient_id} not connected")

            _pids ->
              ConnectionRegistry.send_to_user(recipient_id, event)
          end
        end)

        {:ok, state}
    end
  end

  # ─── Helpers ─────────────────────────────────────────────────────────

  defp build_ready(user_id, claims, guild_ids, session_id) do
    Frame.encode(%{
      op: Opcodes.ready(),
      d: %{
        "v" => 1,
        "user" => %{"id" => user_id, "username" => claims["username"] || "unknown"},
        "guilds" => Enum.map(guild_ids, &%{"id" => &1, "unavailable" => false}),
        "session_id" => session_id,
        "resume_gateway_url" =>
          Application.get_env(:nexus_gateway, :gateway_url, "ws://localhost:4000/gateway/v1"),
        "shard" => nil
      },
      s: nil,
      t: nil
    })
  end

  # レート制限のキーとして使う識別子。接続プロセス自身の pid を使う。
  defp conn_id(_state), do: self() |> :erlang.pid_to_list() |> List.to_string()

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp schedule_hb_check(ms) do
    Process.send_after(self(), :check_heartbeat, ms)
  end
end
