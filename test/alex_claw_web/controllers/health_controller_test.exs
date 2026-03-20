defmodule AlexClawWeb.HealthControllerTest do
  use AlexClawWeb.ConnCase, async: false

  describe "GET /health" do
    test "returns 200 with status ok when DB is up", %{conn: conn} do
      conn = get(conn, "/health")
      body = json_response(conn, 200)

      assert body["status"] == "ok"
      assert body["db"] == "connected"
      assert is_binary(body["version"])
    end

    test "does not require authentication", %{conn: conn} do
      conn = get(conn, "/health")
      assert conn.status == 200
    end

    test "returns JSON content-type", %{conn: conn} do
      conn = get(conn, "/health")
      assert {"content-type", content_type} = List.keyfind(conn.resp_headers, "content-type", 0)
      assert content_type =~ "application/json"
    end
  end
end
