defmodule AlexClawWeb.AdminLive.WorkflowRunsTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows

  describe "mount" do
    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/workflows/1/runs")
      assert redirected_to(conn) == "/login"
    end

    test "renders with valid workflow when authenticated", %{conn: conn} do
      {:ok, workflow} = Workflows.create_workflow(%{name: "Test WF", enabled: false})
      conn = conn |> authenticate() |> get("/workflows/#{workflow.id}/runs")
      assert html_response(conn, 200) =~ "Test WF"
    end
  end
end
