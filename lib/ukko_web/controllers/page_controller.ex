defmodule UkkoWeb.PageController do
  use UkkoWeb, :controller

  def index(conn, _params) do
    index_path = Application.app_dir(:ukko, "priv/static/index.html")

    if File.exists?(index_path) do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, index_path)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, "Ukko API is running. Build frontend to serve static assets.")
    end
  end
end

