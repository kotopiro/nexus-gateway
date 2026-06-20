defmodule NexusGateway.Auth do
  @moduledoc """
  JWT 検証。
  プロトタイプ: HMAC-SHA256 (HS256)。
  本番移行時: RS256 + JWKS エンドポイント に変更予定。
  """

  use Joken.Config

  @impl Joken.Config
  def token_config do
    # exp (有効期限) のみ検証。aud は skip。
    default_claims(skip: [:aud, :iss])
  end

  @doc "Access Token を検証して claims を返す"
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, :token_expired | :invalid_token}
  def verify_token(token) when is_binary(token) do
    signer = build_signer()

    case verify_and_validate(token, signer) do
      {:ok, claims} ->
        {:ok, claims}

      {:error, [message: "Invalid token", claim: "exp", claim_val: _]} ->
        {:error, :token_expired}

      {:error, _} ->
        {:error, :invalid_token}
    end
  end

  def verify_token(_), do: {:error, :invalid_token}

  @doc """
  開発・テスト用トークン生成。
  本番では nexus-api が発行する。

  ## 使い方
      iex> {:ok, token, _} = NexusGateway.Auth.generate_token("user_123", "Kai")
  """
  def generate_token(user_id, username) do
    extra = %{"sub" => user_id, "username" => username}
    signer = build_signer()
    generate_and_sign(extra, signer)
  end

  defp build_signer do
    secret = Application.get_env(:nexus_gateway, :jwt_secret, "dev_secret")
    Joken.Signer.create("HS256", secret)
  end
end
