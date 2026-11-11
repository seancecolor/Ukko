defmodule UkkoWeb.HealthController do
  use UkkoWeb, :controller

  def index(conn, _params) do
    version =
      case Application.spec(:ukko, :vsn) do
        vsn when is_list(vsn) -> List.to_string(vsn)
        _ -> "0.1.8"
      end

    conn
    |> put_status(:ok)
    |> json(%{status: "ok", version: version})
  end
end

