defmodule AlexClawWeb.WorkflowExportController do
  @moduledoc "Serves workflow definitions as downloadable JSON files."

  use Phoenix.Controller, formats: [:json]
  import Plug.Conn

  alias AlexClaw.Workflows

  @spec export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def export(conn, %{"id" => id}) do
    case Workflows.get_workflow(id) do
      {:ok, workflow} ->
        json_data = workflow |> Workflows.export_workflow() |> Jason.encode!(pretty: true)
        safe_name = workflow.name |> String.replace(~r/[^\w\s-]/u, "") |> String.replace(~r/\s+/, "_")
        filename = "#{safe_name}.json"

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, json_data)

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> text("Workflow not found")
    end
  end
end
