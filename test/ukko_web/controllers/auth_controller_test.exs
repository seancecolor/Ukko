defmodule UkkoWeb.AuthControllerTest do
  use UkkoWeb.ConnCase, async: false

  setup do
    prev = Application.get_env(:ukko, :ukko_passcode)
    Application.put_env(:ukko, :ukko_passcode, "test-secret-passcode")
    on_exit(fn -> Application.put_env(:ukko, :ukko_passcode, prev) end)
    :ok
  end

  test "POST /api/auth returns 200 and token with valid passcode", %{conn: conn} do
    conn = post(conn, ~p"/api/auth", %{"passcode" => "test-secret-passcode"})
    assert %{"authenticated" => true, "token" => token} = json_response(conn, 200)
    assert is_binary(token)
  end

  test "POST /api/auth returns 401 with invalid passcode", %{conn: conn} do
    conn = post(conn, ~p"/api/auth", %{"passcode" => "wrong"})
    assert %{"error" => "Invalid passcode"} = json_response(conn, 401)
  end

  test "GET /api/events returns 401 without authentication", %{conn: conn} do
    conn = get(conn, ~p"/api/events")
    assert %{"error" => "Unauthorized"} = json_response(conn, 401)
  end
end
