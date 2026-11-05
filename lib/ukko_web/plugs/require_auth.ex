defmodule UkkoWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug that verifies either a signed Phoenix bearer token (`Authorization: Bearer <token>`)
  or an authenticated session cookie.
  """
  import Plug.Conn
  import Phoenix.Controller

  @token_salt "ukko_auth"
  # 30 days in seconds
  @max_age 86_400 * 30

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      valid_bearer_token?(conn) ->
        conn

      get_session(conn, :authenticated) == true ->
        conn

      true ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Unauthorized"})
        |> halt()
    end
  end

  def sign_token do
    Phoenix.Token.sign(UkkoWeb.Endpoint, @token_salt, "authenticated")
  end

  def verify_token(token) when is_binary(token) do
    Phoenix.Token.verify(UkkoWeb.Endpoint, @token_salt, token, max_age: @max_age)
  end

  defp valid_bearer_token?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        match?({:ok, "authenticated"}, verify_token(String.trim(token)))

      ["bearer " <> token] ->
        match?({:ok, "authenticated"}, verify_token(String.trim(token)))

      _ ->
        false
    end
  end
end
