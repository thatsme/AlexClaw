defmodule AlexClawWeb.AdminLive.WorkflowRuns do
  @moduledoc "LiveView page displaying execution history and step-level results for a workflow."

  use Phoenix.LiveView

  alias AlexClaw.Workflows

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case parse_id(id) do
      :error ->
        {:ok, socket |> put_flash(:error, "Invalid workflow ID") |> redirect(to: "/workflows")}

      {:ok, wf_id} ->
        case Workflows.get_workflow(wf_id) do
          {:ok, workflow} ->
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-bold text-white">Run History</h1>
          <p class="text-sm text-gray-400">Workflow: {@workflow.name}</p>
        </div>
        <div class="flex space-x-3">
          <button phx-click="refresh" class="px-4 py-2 bg-gray-800 hover:bg-gray-700 text-white text-sm rounded transition">
            Refresh
          </button>
          <button :if={@runs != []} phx-click="clear_runs" data-confirm="Delete all run history for this workflow?"
            class="px-4 py-2 bg-red-800 hover:bg-red-700 text-white text-sm rounded transition">
            Clear History
          </button>
          <a href="/workflows" class="px-4 py-2 bg-gray-800 hover:bg-gray-700 text-white text-sm rounded transition">
            Back
          </a>
        </div>
      </div>

      <div class="space-y-3">
        <div :if={@runs == []} class="bg-gray-900 rounded-lg border border-gray-800 p-8 text-center text-gray-500">
          No runs yet. Use "Run Now" from the workflows page.
        </div>

        <div :for={run <- @runs} class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
          <div phx-click="toggle_expand" phx-value-id={run.id}
            class="px-4 py-3 flex items-center justify-between cursor-pointer hover:bg-gray-800/50">
            <div class="flex items-center space-x-4">
              <span class={"text-xs px-2 py-1 rounded #{status_class(run.status)}"}>{run.status}</span>
              <span class="text-sm text-gray-400">Run #{run.id}</span>
              <span class="text-xs text-gray-500">{format_datetime(run.started_at)}</span>
            </div>
            <div class="flex items-center space-x-4">
              <span class="text-xs text-gray-500">Duration: {duration(run)}</span>
              <span class="text-xs text-gray-500">{if MapSet.member?(@expanded, run.id), do: "Collapse", else: "Expand"}</span>
            </div>
          </div>

          <div :if={MapSet.member?(@expanded, run.id)} class="border-t border-gray-800 px-4 py-4 space-y-3">
            <div :if={run.error} class="bg-red-900/30 border border-red-800 rounded p-3">
              <p class="text-xs text-red-300 font-mono">{run.error}</p>
            </div>

            <div :if={run.step_results != %{}} class="space-y-2">
              <h4 class="text-sm font-semibold text-gray-300">Step Results</h4>
              <div :for={{pos, step_data} <- Enum.sort_by(run.step_results, fn {k, _} -> case Integer.parse(k) do {i, _} -> i; :error -> 0 end end)}
                class="bg-gray-800 rounded p-3">
                <div class="flex items-center justify-between mb-1">
                  <span class="text-sm text-white font-semibold">
                    Step {pos}: {step_data["name"]}
                  </span>
                  <span class="text-xs px-2 py-0.5 rounded bg-gray-700 text-claw-500">{step_data["skill"]}</span>
                </div>
                <div :if={step_data["output"]} class="text-xs text-gray-400 font-mono whitespace-pre-wrap max-h-48 overflow-y-auto">
                  {truncate_output(step_data["output"])}
                </div>
                <div :if={step_data["error"]} class="text-xs text-red-400 font-mono">
                  {step_data["error"]}
                </div>
              </div>
            </div>

            <div :if={run.result != %{}} class="bg-gray-800 rounded p-3">
              <h4 class="text-sm font-semibold text-gray-300 mb-1">Final Result</h4>
              <div class="text-xs text-gray-400 font-mono whitespace-pre-wrap max-h-48 overflow-y-auto">
                {truncate_output(run.result["output"])}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

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
