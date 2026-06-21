defmodule NexusGateway.Permissions do
  @moduledoc """
  チャンネル権限のビットフラグ定義と判定ロジック。

  Discord ライクなビットフラグ方式。PostgreSQL の roles.permissions (BIGINT) と対応。

  プロトタイプでは DataSource.Stub が常に `all()` を返すため
  実質的に権限チェックは無効化されている。本番投入前に Stub の挙動を
  見直すこと (CHANGELOG 参照)。
  """

  @type permission_set :: non_neg_integer()

  import Bitwise

  @view_channel 1 <<< 0
  @send_messages 1 <<< 1
  @send_typing 1 <<< 2
  @add_reactions 1 <<< 3
  @attach_files 1 <<< 4
  @manage_messages 1 <<< 5
  @manage_channel 1 <<< 6
  @connect_voice 1 <<< 7
  @speak_voice 1 <<< 8
  @mention_everyone 1 <<< 9
  @manage_roles 1 <<< 10
  @administrator 1 <<< 11

  def view_channel, do: @view_channel
  def send_messages, do: @send_messages
  def send_typing, do: @send_typing
  def add_reactions, do: @add_reactions
  def attach_files, do: @attach_files
  def manage_messages, do: @manage_messages
  def manage_channel, do: @manage_channel
  def connect_voice, do: @connect_voice
  def speak_voice, do: @speak_voice
  def mention_everyone, do: @mention_everyone
  def manage_roles, do: @manage_roles
  def administrator, do: @administrator

  @doc "全権限を持つビットセットを返す (administrator含む)"
  @spec all() :: permission_set()
  def all do
    @view_channel ||| @send_messages ||| @send_typing ||| @add_reactions |||
      @attach_files ||| @manage_messages ||| @manage_channel ||| @connect_voice |||
      @speak_voice ||| @mention_everyone ||| @manage_roles ||| @administrator
  end

  @doc "権限なし"
  @spec none() :: permission_set()
  def none, do: 0

  @doc "DB の BIGINT 値からビットセットを構築する (現状は恒等変換、将来の検証フック用)"
  @spec from_bits(integer()) :: permission_set()
  def from_bits(bits) when is_integer(bits) and bits >= 0, do: bits
  def from_bits(_), do: 0

  @doc "permission_set が指定フラグを含むか判定する。administrator は常に true。"
  @spec has?(permission_set(), permission_set()) :: boolean()
  def has?(set, flag) do
    (set &&& @administrator) != 0 or (set &&& flag) != 0
  end

  @doc """
  ユーザーがチャンネルでメッセージ送信できるか判定する。
  DataSource 経由で権限を取得して判定する。
  """
  @spec can_send_messages?(String.t(), String.t()) :: boolean()
  def can_send_messages?(user_id, channel_id) do
    check(user_id, channel_id, @send_messages)
  end

  @doc "ユーザーが Typing Indicator を送れるか判定する"
  @spec can_send_typing?(String.t(), String.t()) :: boolean()
  def can_send_typing?(user_id, channel_id) do
    check(user_id, channel_id, @send_typing)
  end

  defp check(user_id, channel_id, flag) do
    case NexusGateway.DataSource.fetch_channel_permissions(user_id, channel_id) do
      {:ok, set} -> has?(set, flag)
      {:error, _} -> false
    end
  end
end
