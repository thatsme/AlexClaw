defmodule AlexClawWeb.AdminLive.SmokeTest do
  @moduledoc """
  Smoke tests for all LiveView routes.
  Verifies authentication redirect and basic 200 response when authenticated.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  # Routes already tested in dedicated test files:
  #   /skills     → skills_test.exs
  #   /policies   → policies_test.exs
  #   /workflows/:id/runs → workflow_runs_test.exs
  #
  # This file covers the remaining untested LiveView routes.

  @live_routes [
    {"/", "Dashboard"},
    {"/chat", "Chat"},
    {"/forge", "Forge"},
    {"/scheduler", "Scheduler"},
    {"/llm", "LLM"},
    {"/resources", "Resources"},
    {"/workflows", "Workflows"},
    {"/database", "Database"},
    {"/config", "Config"},
    {"/memory", "Memory"},
    {"/logs", "Logs"},
    {"/cluster", "Cluster"}
  ]

  for {path, label} <- @live_routes do
    describe "GET #{path}" do
      test "redirects to /login when unauthenticated", %{conn: conn} do
        conn = get(conn, unquote(path))
        assert redirected_to(conn) == "/login"
      end

      test "renders when authenticated", %{conn: conn} do
        conn = conn |> authenticate() |> get(unquote(path))
        assert html_response(conn, 200)
      end
    end
  end
end
