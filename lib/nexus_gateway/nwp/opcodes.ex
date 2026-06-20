defmodule NexusGateway.NWP.Opcodes do
  @moduledoc """
  NWP v1 Opcode 定数

  0  DISPATCH           S→C  イベント配信
  1  HEARTBEAT          C→S  死活確認
  2  HEARTBEAT_ACK      S→C  Heartbeat 応答
  3  IDENTIFY           C→S  認証・接続確立
  4  READY              S→C  認証成功・初期状態
  5  RESUME             C→S  切断後の再接続
  6  RESUMED            S→C  Resume 成功
  7  RECONNECT          S→C  再接続要求
  8  INVALID_SESSION    S→C  セッション無効
  9  PRESENCE_UPDATE    C→S  Presence 変更
  10 VOICE_STATE_UPDATE C→S  ボイス参加/退出
  11 REQUEST_MEMBERS    C→S  メンバー一覧要求
  12 TYPING_START       C→S  入力中通知
  13 E2EE_ENVELOPE      両方  暗号化 Blob 転送
  14 MLS_COMMIT         両方  MLS Commit
  15 MLS_WELCOME        S→C  MLS Welcome (新規参加者)
  """

  def dispatch,            do: 0
  def heartbeat,           do: 1
  def heartbeat_ack,       do: 2
  def identify,            do: 3
  def ready,               do: 4
  def resume,              do: 5
  def resumed,             do: 6
  def reconnect,           do: 7
  def invalid_session,     do: 8
  def presence_update,     do: 9
  def voice_state_update,  do: 10
  def request_members,     do: 11
  def typing_start,        do: 12
  def e2ee_envelope,       do: 13
  def mls_commit,          do: 14
  def mls_welcome,         do: 15

  def hello,               do: 16

  @unauthenticated_allowed [3, 5]  # IDENTIFY, RESUME

  def requires_auth?(op), do: op not in @unauthenticated_allowed
end
