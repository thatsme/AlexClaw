defmodule AlexClaw.Cluster.Manager do
  @moduledoc """
  GenServer that manages cluster connectivity and handles incoming
  remote workflow triggers from other BEAM nodes.

  Called via `:rpc.call` from `send_to_workflow` on remote nodes.
  Validates that the target workflow has `receive_from_workflow` as step 1
  before allowing execution. Auto-registers nodes on connection and
  attempts to connect to known nodes on boot.
  """
  use GenServer
  require Logger

  import Ecto.Query

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Called via RPC from a remote node. Validates the target workflow
  has receive_from_workflow as step 1, then starts it with the given data.
  """
  @spec receive_workflow_data(String.t(), any(), String.t()) ::
          {:ok, :started} | {:error, atom() | tuple()}
  def receive_workflow_data(workflow_name, data, source_node) do
    GenServer.call(__MODULE__, {:receive, workflow_name, data, source_node}, 10_000)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Logger.info("ClusterManager started on #{node()}")
    :net_kernel.monitor_nodes(true)
    :timer.send_interval(60_000, :refresh_statuses)
    auto_register_self()
    Process.send_after(self(), :connect_known_nodes, 5_000)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:receive, workflow_name, data, source_node}, _from, state) do
    result = do_receive(workflow_name, data, source_node)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:nodeup, remote_node}, state) do
    name = to_string(remote_node)
    Logger.info("Node connected: #{name}")
    auto_register_node(name)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, remote_node}, state) do
    name = to_string(remote_node)
    Logger.info("Node disconnected: #{name}")

    case AlexClaw.Cluster.get_by_name(name) do
      nil -> :ok
      node -> AlexClaw.Cluster.update_node(node, %{status: "disconnected"})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:connect_known_nodes, state) do
    self_name = to_string(node())

    AlexClaw.Cluster.list_nodes()
    |> Enum.reject(fn n -> n.name == self_name end)
    |> Enum.each(fn n -> AlexClaw.Cluster.node_ping(n.name) end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_statuses, state) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      AlexClaw.Cluster.refresh_statuses()
    end)

    {:noreply, state}
  end

  # --- Internal ---

  defp auto_register_self do
    self_name = to_string(node())

    if self_name != "nonode@nohost" do
      auto_register_node(self_name)
    end
  end

  defp auto_register_node(name) do
    case AlexClaw.Cluster.get_by_name(name) do
      nil ->
        label = name |> String.split("@") |> List.last()

        case AlexClaw.Cluster.create_node(%{
               name: name,
               label: label,
               status: "connected",
               last_seen_at: DateTime.utc_now()
             }) do
          {:ok, _} -> Logger.info("Auto-registered cluster node: #{name}")
          {:error, _} -> Logger.warning("Failed to auto-register node: #{name}")
        end

      existing ->
        AlexClaw.Cluster.update_node(existing, %{
          status: "connected",
          last_seen_at: DateTime.utc_now()
        })
    end
  end

  defp do_receive(workflow_name, data, source_node) do
    alias AlexClaw.Workflows.Workflow

    case AlexClaw.Repo.one(
           from w in Workflow,
             where: w.name == ^workflow_name and w.enabled == true,
             preload: [steps: ^from(s in AlexClaw.Workflows.WorkflowStep, order_by: s.position)]
         ) do
      nil ->
        Logger.warning(
          "Remote trigger rejected: workflow '#{workflow_name}' not found or disabled"
        )

        {:error, :workflow_not_found}

      workflow ->
        first_step = List.first(workflow.steps)

        if first_step && first_step.skill == "receive_from_workflow" do
          Logger.info("Remote trigger accepted: '#{workflow_name}' from #{source_node}")

          Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
            AlexClaw.Workflows.Executor.run_with_input(workflow.id, data, %{
              "_source_node" => source_node
            })
          end)

          {:ok, :started}
        else
          Logger.warning(
            "Remote trigger rejected: '#{workflow_name}' lacks receive_from_workflow gate"
          )

          {:error, :no_receive_gate}
        end
    end
  end
end
