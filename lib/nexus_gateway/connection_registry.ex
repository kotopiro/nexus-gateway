defmodule NexusGateway.ConnectionRegistry do
  @moduledoc """
  user_id → [conn_pid, ...] のマッピング。

  既存の NexusGateway.Registry (Guild プロセス名前解決用) とは別の名前空間で
  接続プロセスを管理する。MLS Welcome のような「特定の1ユーザーにのみ送る」
  ケースで Guild 全体への broadcast を避けるために使う。

  同一ユーザーが複数デバイスで接続する場合に対応するため、
  1 user_id に複数の conn_pid が登録されうる。
  """

  @registry NexusGateway.ConnRegistry

  @doc "Registry の child_spec。Application supervision tree に追加する。"
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc "現在の接続プロセス (self()) を user_id に登録する"
  @spec register(String.t()) :: {:ok, pid()} | {:error, term()}
  def register(user_id) do
    Registry.register(@registry, user_id, nil)
  end

  @doc "現在の接続プロセスの登録を解除する"
  @spec unregister(String.t()) :: :ok
  def unregister(user_id) do
    Registry.unregister(@registry, user_id)
  end

  @doc "user_id に紐づく全接続 pid を返す。接続していなければ空リスト。"
  @spec lookup(String.t()) :: [pid()]
  def lookup(user_id) do
    Registry.lookup(@registry, user_id)
    |> Enum.map(fn {pid, _value} -> pid end)
  end

  @doc "user_id がオンラインか (1つ以上の接続を持つか)"
  @spec online?(String.t()) :: boolean()
  def online?(user_id) do
    lookup(user_id) != []
  end

  @doc "user_id の全接続にイベントを直接送信する。GuildProcess を経由しない。"
  @spec send_to_user(String.t(), map()) :: :ok
  def send_to_user(user_id, event_map) do
    user_id
    |> lookup()
    |> Enum.each(&send(&1, {:dispatch, event_map}))

    :ok
  end
end
