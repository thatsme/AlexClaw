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
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    input = args[:input]
    config = args[:config] || %{}

    target_node = config["target_node"]
    target_workflow = config["target_workflow"]
    timeout = config["timeout"] || @default_timeout

    cond do
      is_nil(target_node) or target_node == "" ->
        {:error, :missing_target_node}

      is_nil(target_workflow) or target_workflow == "" ->
        {:error, :missing_target_workflow}

      true ->
        source_node = to_string(node())

        atom_node =
          try do
            String.to_existing_atom(target_node)
          rescue
            ArgumentError -> nil
          end

        if is_nil(atom_node) do
          {:error, {:rpc_failed, :unknown_node}}
        else
          case :rpc.call(
                 atom_node,
                 AlexClaw.Cluster.Manager,
                 :receive_workflow_data,
                 [target_workflow, input, source_node],
                 timeout
               ) do
            {:ok, _} ->
              Logger.info("Sent data to '#{target_workflow}' on #{target_node}")
              {:ok, input, :on_sent}

            {:error, reason} ->
              Logger.warning("Failed to send to #{target_node}: #{inspect(reason)}")
              {:error, reason}

            {:badrpc, reason} ->
              Logger.warning("RPC failed to #{target_node}: #{inspect(reason)}")
              {:error, {:rpc_failed, reason}}
          end
        end
    end
  end

end
