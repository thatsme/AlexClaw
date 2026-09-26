defmodule AlexClaw.Skills.ReceiveFromWorkflow do
  @moduledoc """
  Gate skill: when placed as step 1, allows a workflow to be triggered
  remotely by another BEAM node via `send_to_workflow`.

  Passes through the received data as output. Rejects nil input and
  optionally validates the source node against an allowlist.

  Config:
    - `allowed_nodes` (list): the registered cluster nodes allowed to trigger
      this workflow. Empty or absent allows no one: a workflow names who may
      trigger it (since 0.4.0).
  """
  @behaviour AlexClaw.Skill

  @impl true
  @spec description() :: String.t()
  def description, do: "Gate: allows this workflow to be triggered remotely by another node"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_success, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint,
    do: ~s|{"allowed_nodes": ["node@host"]} — the registered nodes that may trigger it|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"allowed_nodes" => []}

  # _source_node is set by the executor for a run a remote node started; keys
  # starting with _ are the runtime's, not a step's.
  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema, do: %{"allowed_nodes" => %{type: :list, required: false}}

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "Gate skill — must be step 1. allowed_nodes: the registered cluster nodes that may trigger this workflow. Empty allows no one."

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    gate(args[:input], config["_source_node"], config["allowed_nodes"] || [])
  end

  defp gate(nil, _source_node, _allowed), do: {:error, :no_input_received}

  # The node must be named: an empty list allows no one.
  defp gate(input, source_node, allowed),
    do: admitted(is_list(allowed) and source_node in allowed, input, source_node)

  defp admitted(true, input, _source_node), do: {:ok, input, :on_success}
  defp admitted(false, _input, source_node), do: {:error, {:unauthorized_node, source_node}}
end
