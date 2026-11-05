defmodule UkkoWeb.AuthController do
  use UkkoWeb, :controller

  alias UkkoWeb.Plugs.RequireAuth

  @doc """
  POST /api/auth
  Validates `passcode` against `UKKO_PASSCODE` and returns a signed Phoenix token and session cookie.
  """
  def create(conn, params) do
    provided = Map.get(params, "passcode", "")
    expected = Application.get_env(:ukko, :ukko_passcode)

    if is_binary(expected) and expected != "" and is_binary(provided) and
         Plug.Crypto.secure_compare(provided, expected) do
      token = RequireAuth.sign_token()

      conn
      |> put_session(:authenticated, true)
      |> put_status(:ok)
      |> json(%{token: token, authenticated: true})
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Invalid passcode"})
    end
  end
end
