defmodule AlexClaw.Workflows.SchedulerSync do
  @moduledoc """
  Syncs DB-defined workflow schedules with Quantum.
  On boot, reads all scheduled workflows and registers them as Quantum jobs.
  Call sync/0 after creating/updating/deleting workflows.
  """
  use GenServer
  require Logger

  alias AlexClaw.Workflows

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Re-sync all workflow schedules with Quantum."
  @spec sync() :: :ok
  def sync do
    GenServer.cast(__MODULE__, :sync)
  end

  # --- Callbacks ---

  @impl true
  def init(:ok) do
    # Delay sync to ensure Repo and Scheduler are ready
    Process.send_after(self(), :sync, 3_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sync, state) do
    do_sync()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:sync, state) do
    do_sync()
    {:noreply, state}
  end

  defp do_sync do
    # Remove all workflow-managed jobs (prefixed with :wf_)
    Enum.each(AlexClaw.Scheduler.jobs(), fn {name, _job} ->
      if is_atom(name) and String.starts_with?(Atom.to_string(name), "wf_") do
        AlexClaw.Scheduler.delete_job(name)
      end
    end)

    # Add jobs for all enabled scheduled workflows
    workflows = Workflows.list_scheduled_workflows()

    Enum.each(workflows, fn workflow ->
      job_name = :"wf_#{workflow.id}"

      case Crontab.CronExpression.Parser.parse(workflow.schedule) do
        {:ok, cron} ->
          job =
            AlexClaw.Scheduler.new_job()
            |> Quantum.Job.set_name(job_name)
            |> Quantum.Job.set_schedule(cron)
            |> Quantum.Job.set_task({AlexClaw.Workflows.Executor, :run, [workflow.id]})

          AlexClaw.Scheduler.add_job(job)
          Logger.info("Scheduled workflow '#{workflow.name}' as #{job_name}: #{workflow.schedule}")

        {:error, reason} ->
          Logger.warning("Invalid cron for workflow '#{workflow.name}': #{inspect(reason)}")
      end
    end)
  end
end
