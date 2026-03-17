defmodule AlexClawWeb.AdminLive.Scheduler do
  @moduledoc "LiveView page showing scheduled workflows, next run times, and manual triggers."

  use Phoenix.LiveView

  alias AlexClaw.Workflows

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(30_000, :refresh)
    end

    {:ok,
     assign(socket,
       page_title: "Scheduler",
       jobs: list_jobs()
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, jobs: list_jobs())}
  end

  @impl true
  def handle_event("run_now", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, wf_id} ->
        case Workflows.get_workflow(wf_id) do
          {:ok, workflow} ->
            Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn -> AlexClaw.Workflows.Executor.run(workflow.id) end)
            {:noreply, put_flash(socket, :info, "Workflow '#{workflow.name}' triggered")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Workflow not found")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid workflow ID")}
    end
  end

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, assign(socket, jobs: list_jobs())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-bold text-white">Scheduler</h1>
          <p class="text-xs text-gray-500 mt-1">{length(@jobs)} scheduled workflows</p>
        </div>
        <button phx-click="refresh" class="px-4 py-2 bg-gray-800 hover:bg-gray-700 text-white text-sm rounded transition">
          Refresh
        </button>
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
        <table class="w-full">
          <thead class="bg-gray-800">
            <tr>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Workflow</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Schedule</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Next Run</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">State</th>
              <th class="px-4 py-3 text-right text-xs text-gray-400 uppercase">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@jobs == []} class="border-t border-gray-800">
              <td colspan="5" class="px-4 py-8 text-center text-gray-500">
                No scheduled workflows. Set a cron schedule in the
                <a href="/workflows" class="text-claw-500 hover:text-claw-400">Workflows</a> editor.
              </td>
            </tr>
            <tr :for={job <- @jobs} class="border-t border-gray-800">
              <td class="px-4 py-3">
                <div class="text-sm font-semibold text-claw-500">{job.workflow_name}</div>
                <div :if={job.description} class="text-xs text-gray-500">{job.description}</div>
              </td>
              <td class="px-4 py-3">
                <span class="text-sm font-mono text-gray-300">{job.schedule_display}</span>
                <div class="text-xs text-gray-600">{job.schedule_label}</div>
              </td>
              <td class="px-4 py-3">
                <span class={"text-sm " <> if(job.minutes_until && job.minutes_until <= 10, do: "text-yellow-400", else: "text-gray-300")}>
                  {job.next_run_display}
                </span>
              </td>
              <td class="px-4 py-3">
                <span class={["text-xs px-2 py-1 rounded",
                  job.state == :active && "bg-green-900 text-green-300",
                  job.state != :active && "bg-gray-800 text-gray-500"]}>
                  {job.state}
                </span>
              </td>
              <td class="px-4 py-3 text-right space-x-2">
                <button phx-click="run_now" phx-value-id={job.workflow_id}
                  class="text-xs text-green-500 hover:text-green-400">Run Now</button>
                <a href={"/workflows/#{job.workflow_id}/runs"} class="text-xs text-claw-500 hover:text-claw-400">History</a>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp list_jobs do
    quantum_jobs =
      AlexClaw.Scheduler.jobs()
      |> Map.new(fn {name, job} -> {name, job} end)

    Workflows.list_scheduled_workflows()
    |> Enum.map(fn workflow ->
      job_name = :"wf_#{workflow.id}"
      quantum_job = Map.get(quantum_jobs, job_name)

      %{
        workflow_id: workflow.id,
        workflow_name: workflow.name,
        description: workflow.description,
        schedule_display: workflow.schedule,
        schedule_label: schedule_label(workflow.schedule),
        next_run_display: next_run_display(quantum_job),
        minutes_until: minutes_until_next(quantum_job),
        state: if(quantum_job, do: quantum_job.state, else: :inactive)
      }
    end)
  end

  defp next_run_display(nil), do: "Not synced"

  defp next_run_display(job) do
    case Crontab.Scheduler.get_next_run_date(job.schedule) do
      {:ok, next} ->
        now = NaiveDateTime.utc_now()
        diff_minutes = NaiveDateTime.diff(next, now, :second) |> div(60)

        cond do
          diff_minutes < 1 -> "< 1 min"
          diff_minutes < 60 -> "in #{diff_minutes} min"
          diff_minutes < 1440 -> "in #{div(diff_minutes, 60)}h #{rem(diff_minutes, 60)}m"
          true -> AlexClawWeb.TimeHelpers.format_datetime(next)
        end

      _ ->
        "—"
    end
  end

  defp minutes_until_next(nil), do: nil

  defp minutes_until_next(job) do
    case Crontab.Scheduler.get_next_run_date(job.schedule) do
      {:ok, next} -> NaiveDateTime.diff(next, NaiveDateTime.utc_now(), :second) |> div(60)
      _ -> nil
    end
  end

  @schedule_presets %{
    "*/15 * * * *" => "Every 15 min",
    "*/30 * * * *" => "Every 30 min",
    "0 * * * *" => "Every hour",
    "0 */2 * * *" => "Every 2 hours",
    "0 */4 * * *" => "Every 4 hours",
    "0 */6 * * *" => "Every 6 hours",
    "0 */12 * * *" => "Every 12 hours",
    "0 7 * * *" => "Daily 7:00",
    "0 8 * * *" => "Daily 8:00",
    "0 9 * * *" => "Daily 9:00",
    "0 12 * * *" => "Daily 12:00",
    "0 18 * * *" => "Daily 18:00",
    "0 21 * * *" => "Daily 21:00",
    "0 7 * * 1-5" => "Weekdays 7:00",
    "0 9 * * 1-5" => "Weekdays 9:00",
    "0 9 * * 1" => "Monday 9:00",
    "0 9 * * 5" => "Friday 9:00",
    "0 9 1 * *" => "Monthly 1st 9:00"
  }

  defp schedule_label(schedule) do
    Map.get(@schedule_presets, schedule, "Custom")
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end
end
