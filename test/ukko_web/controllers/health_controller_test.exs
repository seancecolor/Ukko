defmodule UkkoWeb.HealthControllerTest do
  use UkkoWeb.ConnCase, async: true

  test "GET /api/health returns 200 OK", %{conn: conn} do
    conn = get(conn, ~p"/api/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end

