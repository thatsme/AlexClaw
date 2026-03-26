defmodule AlexClawWeb.AdminLive.WorkflowRuns do
  @moduledoc "LiveView page displaying execution history and step-level results for a workflow."

  use Phoenix.LiveView

  alias AlexClaw.Workflows

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(%{"id" => id}, _session, socket) do
    case parse_id(id) do
      :error ->
        {:ok, socket |> put_flash(:error, "Invalid workflow ID") |> redirect(to: "/workflows")}

      {:ok, wf_id} ->
        case Workflows.get_workflow(wf_id) do
          {:ok, workflow} ->
            if connected?(socket) do
              Phoenix.PubSub.subscribe(AlexClaw.PubSub, AlexClaw.Workflows.Registry.topic())
            end

            runs = Workflows.list_runs(workflow.id)

            {:ok,
             assign(socket,
               page_title: "Runs: #{workflow.name}",
               workflow: workflow,
               runs: runs,
               expanded: MapSet.new()
             )}

          {:error, :not_found} ->
            {:ok,
             socket
             |> put_flash(:error, "Workflow not found")
             |> redirect(to: "/workflows")}
        end
    end
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_expand", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, run_id} ->
        expanded = socket.assigns.expanded

        expanded =
          if MapSet.member?(expanded, run_id) do
            MapSet.delete(expanded, run_id)
          else
            MapSet.put(expanded, run_id)
          end

        {:noreply, assign(socket, expanded: expanded)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh", _, socket) do
    runs = Workflows.list_runs(socket.assigns.workflow.id)
    {:noreply, assign(socket, runs: runs)}
  end

  @impl true
  def handle_event("clear_runs", _, socket) do
    Workflows.clear_runs(socket.assigns.workflow.id)

    {:noreply,
     socket
     |> put_flash(:info, "Run history cleared")
     |> assign(runs: [], expanded: MapSet.new())}
  end

  @impl true
  def handle_info({event, %{workflow_id: wf_id}}, socket)
      when event in [:workflow_run_started, :workflow_run_completed, :workflow_run_failed, :workflow_run_cancelled]
      and wf_id == socket.assigns.workflow.id do
    runs = Workflows.list_runs(socket.assigns.workflow.id)
    {:noreply, assign(socket, runs: runs)}
  end

  def handle_info({:workflow_step_completed, _}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: AlexClawWeb.TimeHelpers.format_datetime(dt)

  defp duration(run) do
    if run.started_at && run.completed_at do
      seconds = DateTime.diff(run.completed_at, run.started_at)
      "#{seconds}s"
    else
      "-"
    end
  end

  defp status_class("completed"), do: "bg-green-900 text-green-300"
  defp status_class("running"), do: "bg-blue-900 text-blue-300"
  defp status_class("failed"), do: "bg-red-900 text-red-300"
  defp status_class("cancelled"), do: "bg-gray-800 text-gray-400"
  defp status_class(_), do: "bg-gray-800 text-gray-400"

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp truncate_output(nil), do: "-"
  defp truncate_output(output) when is_binary(output) do
    if String.length(output) > 2000 do
      String.slice(output, 0, 2000) <> "\n... (truncated)"
    else
      output
    end
  end
  defp truncate_output(output) when is_map(output), do: Jason.encode!(output, pretty: true)
  defp truncate_output(output), do: inspect(output)
end
