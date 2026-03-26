defmodule AlexClawWeb.AdminLive.Scheduler do
  @moduledoc "LiveView page showing scheduled workflows, next run times, and manual triggers."

  use Phoenix.LiveView

  alias AlexClaw.Workflows

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
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
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
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

  defp list_jobs do
    quantum_jobs =
      Map.new(AlexClaw.Scheduler.jobs(), fn {name, job} -> {name, job} end)

    Enum.map(Workflows.list_scheduled_workflows(), fn workflow ->
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
        diff_minutes = div(NaiveDateTime.diff(next, now, :second), 60)

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
      {:ok, next} -> div(NaiveDateTime.diff(next, NaiveDateTime.utc_now(), :second), 60)
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
