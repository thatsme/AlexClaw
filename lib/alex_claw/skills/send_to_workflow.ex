defmodule AlexClaw.Skills.SendToWorkflow do
  @moduledoc """
  Sends the current step's input to a workflow on another BEAM node.

  The remote node must have the target workflow with `receive_from_workflow`
  as its first step, otherwise the trigger is rejected.

  Config (required):
    - `target_node`: BEAM node name, e.g. "node_work@192.168.1.20"
    - `target_workflow`: workflow name on the remote node

  Config (optional):
    - `timeout`: RPC timeout in milliseconds (default: 5000)
  """
  @behaviour AlexClaw.Skill
  require Logger

  @default_timeout 5_000

  @impl true
  @spec description() :: String.t()
  def description, do: "Sends workflow output to a workflow on another BEAM node"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_sent, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint,
    do: ~s|{"target_node": "node_name@host", "target_workflow": "workflow name", "timeout": 5000}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"target_node" => "", "target_workflow" => "", "timeout" => 5000}

  # Without a target node and workflow the step cannot run at all.
  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema do
    %{
      "target_node" => %{type: :string, required: true},
      "target_workflow" => %{type: :string, required: true},
      "timeout" => %{type: :integer, required: false}
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "target_node: BEAM node name (e.g. node_work@192.168.1.20). target_workflow: name of the workflow on the remote node. timeout: RPC timeout in ms (default 5000)."

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}

    dispatch(
      config["target_node"],
      config["target_workflow"],
      args[:input],
      config["timeout"] || @default_timeout
    )
  end

  defp dispatch(node, _workflow, _input, _timeout) when node in [nil, ""],
    do: {:error, :missing_target_node}

  defp dispatch(_node, workflow, _input, _timeout) when workflow in [nil, ""],
    do: {:error, :missing_target_workflow}

  defp dispatch(node, workflow, input, timeout) do
    send_to_node(existing_node_atom(node), node, workflow, input, timeout)
  end

  # The target must already be a known node: building the atom from config would
  # leak atoms on every unreachable name.
  defp existing_node_atom(node) do
    String.to_existing_atom(node)
  rescue
    ArgumentError -> nil
  end

  defp send_to_node(nil, _target, _workflow, _input, _timeout),
    do: {:error, {:rpc_failed, :unknown_node}}

  defp send_to_node(atom_node, target, workflow, input, timeout) do
    atom_node
    |> :rpc.call(
      AlexClaw.Cluster.Manager,
      :receive_workflow_data,
      [workflow, input, to_string(node())],
      timeout
    )
    |> rpc_result(target, workflow, input)
  end

  defp rpc_result({:ok, _}, target, workflow, input) do
    Logger.info("Sent data to '#{workflow}' on #{target}")
    {:ok, input, :on_sent}
  end

  defp rpc_result({:error, reason}, target, _workflow, _input) do
    Logger.warning("Failed to send to #{target}: #{inspect(reason)}")
    {:error, reason}
  end

  defp rpc_result({:badrpc, reason}, target, _workflow, _input) do
    Logger.warning("RPC failed to #{target}: #{inspect(reason)}")
    {:error, {:rpc_failed, reason}}
  end
end
