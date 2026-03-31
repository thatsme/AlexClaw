defmodule AlexClawWeb.MetricsControllerTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  describe "GET /metrics" do
    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/metrics")
      assert redirected_to(conn) == "/login"
    end

    test "returns all metric sections when authenticated", %{conn: conn} do
      conn = conn |> authenticate() |> get("/metrics")
      body = json_response(conn, 200)

      assert Map.has_key?(body, "system")
      assert Map.has_key?(body, "llm")
      assert Map.has_key?(body, "workflows")
      assert Map.has_key?(body, "skills")
      assert Map.has_key?(body, "mcp")
      assert Map.has_key?(body, "logs")
      assert Map.has_key?(body, "knowledge")
      assert Map.has_key?(body, "memory")
    end

    test "mcp section has expected keys", %{conn: conn} do
      conn = conn |> authenticate() |> get("/metrics")
      mcp = json_response(conn, 200)["mcp"]

      assert mcp["status"] in ["running", "disabled"]
      assert is_integer(mcp["tools_registered"]) and mcp["tools_registered"] >= 0
    end

    test "system section has expected keys", %{conn: conn} do
      conn = conn |> authenticate() |> get("/metrics")
      system = json_response(conn, 200)["system"]

      assert is_integer(system["uptime_seconds"]) and system["uptime_seconds"] >= 0
      assert is_integer(system["memory_bytes"]) and system["memory_bytes"] > 0
      assert is_integer(system["beam_process_count"]) and system["beam_process_count"] > 0
    end

    test "workflows section shows today's counts", %{conn: conn} do
      conn = conn |> authenticate() |> get("/metrics")
      workflows = json_response(conn, 200)["workflows"]

      assert is_integer(workflows["total"])
      assert is_integer(workflows["completed"])
      assert is_integer(workflows["failed"])
      assert is_integer(workflows["running"])
    end

    test "llm section includes providers list", %{conn: conn} do
      conn = conn |> authenticate() |> get("/metrics")
      llm = json_response(conn, 200)["llm"]

      assert is_list(llm["providers"])
      assert is_integer(llm["total_calls_today"])
    end
  end
end
