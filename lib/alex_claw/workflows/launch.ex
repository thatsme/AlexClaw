defmodule AlexClaw.Workflows.Launch do
  @moduledoc """
  The one rule for starting a workflow run from the admin UI.

  A workflow marked `requires_2fa` is challenged; anything else starts at once.
  The rule lives here because two pages start runs — Workflows and Scheduler —
  and when the check lived in one of them, the other was a way around it.

  The gateway path has its own copy of this decision by necessity: it arrives
  as a message rather than a click. Both end in the same
  `execute_2fa_action(%{type: :run_workflow, ...})`.
  """

  alias AlexClaw.Auth.Gate
  alias AlexClaw.Workflows.{Executor, Workflow}

  @type result :: :started | :challenged | :no_2fa | {:locked, pos_integer()}

  @doc """
  Start `workflow`, or ask for a second factor first.

  Returns `:started` when the run was handed to the task supervisor,
  `:challenged` when a code was requested, `:no_2fa` when the workflow
  demands a second factor the instance cannot ask for, and `{:locked, minutes}`
  when code entry is locked — both refusals.
  """
  @spec start(Workflow.t()) :: result()
  def start(%Workflow{} = workflow) do
    launch(workflow, workflow.metadata["requires_2fa"])
  end

  @doc """
  How to report a launch to the operator.

  Lives next to the rule so the two pages that start runs cannot drift into
  telling the user different things about the same outcome.
  """
  @spec describe(result(), Workflow.t()) :: {:info | :error, String.t()}
  def describe(:started, %Workflow{name: name}), do: {:info, "Workflow '#{name}' triggered"}

  def describe(:challenged, _workflow),
    do: {:info, "2FA code requested — check Telegram/Discord"}

  def describe({:locked, minutes}, _workflow),
    do: {:error, "Code entry is locked after too many wrong codes — try again in #{minutes} min."}

  def describe(:no_2fa, _workflow),
    do: {:error, "This workflow requires 2FA. Enable 2FA and configure a gateway first."}

  @doc """
  Whether this workflow's own flag demands a second factor before it runs.

  The page asks so it can offer a code field; `start/1` asks so it can raise
  the challenge. One flag, read in one way.
  """
  @spec needs_code?(Workflow.t()) :: boolean()
  def needs_code?(%Workflow{} = workflow) do
    workflow.metadata["requires_2fa"] not in [nil, false]
  end

  defp launch(workflow, requires_2fa) when requires_2fa in [nil, false] do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn -> Executor.run(workflow.id) end)

    :started
  end

  defp launch(workflow, _requires_2fa) do
    Gate.request(
      %{type: :run_workflow, workflow_id: workflow.id},
      "Run workflow: *#{workflow.name}*"
    )
  end
end
