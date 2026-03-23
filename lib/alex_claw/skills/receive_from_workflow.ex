defmodule AlexClaw.Skills.ReceiveFromWorkflow do
  @moduledoc """
  Gate skill: when placed as step 1, allows a workflow to be triggered
  remotely by another BEAM node via `send_to_workflow`.

  Passes through the received data as output. Rejects nil input and
  optionally validates the source node against an allowlist.

  Config:
    - `allowed_nodes` (list, optional): node names allowed to trigger this workflow.
      If empty or absent, any registered cluster node is accepted.
  """
  @behaviour AlexClaw.Skill

  @impl true
  def description, do: "Gate: allows this workflow to be triggered remotely by another node"

  @impl true
  def routes, do: [:on_success, :on_error]

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    input = args[:input]
    config = args[:config] || %{}

    allowed_nodes = config["allowed_nodes"]
    source_node = config["_source_node"]

    cond do
      is_nil(input) ->
        {:error, :no_input_received}

      is_list(allowed_nodes) and allowed_nodes != [] and source_node not in allowed_nodes ->
        {:error, {:unauthorized_node, source_node}}

      true ->
        {:ok, input, :on_success}
    end
  end
end
