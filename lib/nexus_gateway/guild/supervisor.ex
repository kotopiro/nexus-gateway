defmodule NexusGateway.Guild.Supervisor do
  @moduledoc """
  GuildProcess の DynamicSupervisor。

  1 Guild = 1 GuildProcess (GenServer)。
  リクエスト時に起動、誰もいなくなっても停止しない (TODO: 将来的にアイドル停止)。
  """

  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "GuildProcess を起動。既に起動中なら何もしない。"
  @spec ensure_started(String.t()) :: :ok | {:error, term()}
  def ensure_started(guild_id) do
    spec = {NexusGateway.Guild.Process, guild_id}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid}                        -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason}                   -> {:error, reason}
    end
  end

  @doc "起動中の GuildProcess 数"
  @spec count() :: non_neg_integer()
  def count do
    DynamicSupervisor.count_children(__MODULE__).active
  end
end
