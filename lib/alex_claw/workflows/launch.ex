defmodule AlexClaw.Workflows.Launch do
  @moduledoc """
  The one rule for starting a workflow run from the admin UI, and how its
  outcome is told.

  A workflow marked `requires_2fa` is run as `:run_protected_workflow`, with a
  code for that run; anything else as `:run_workflow`. Both go through
  `AlexClaw.ControlPlane.perform/3`. The rule lives here because two pages
  start runs — Workflows and Scheduler — and when the check lived in one of
  them, the other was a way around it.
  """

  alias AlexClaw.Workflows.Workflow

  @doc """
  How to report a run's start to the operator: what
  `AlexClaw.ControlPlane.perform/3` answered for it.

  Lives next to the rule so the two pages that start runs cannot drift into
  telling the user different things about the same outcome.
  """
  @spec describe({:ok, {:started, Workflow.t()}} | {:error, term()}, Workflow.t()) ::
          {:info | :error, String.t()}
  def describe({:ok, {:started, _started}}, %Workflow{name: name}),
    do: {:info, "Workflow '#{name}' triggered"}

  def describe({:error, :workflow_disabled}, %Workflow{name: name}),
    do: {:error, "Workflow '#{name}' is disabled — enable it to run it."}

  def describe({:error, reason}, _workflow),
    do: {:error, "The run was not started: #{inspect(reason)}"}

  @doc """
  Whether this workflow's own flag demands a second factor before it runs.

  The page asks so it can offer a code field. One flag, read in one way:
  `Workflow.protected?/1`.
  """
  @spec needs_code?(Workflow.t()) :: boolean()
  def needs_code?(%Workflow{} = workflow), do: Workflow.protected?(workflow)
end
