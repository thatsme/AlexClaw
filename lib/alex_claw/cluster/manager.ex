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

  alias AlexClaw.BootRetry
  alias AlexClaw.Workflows.Executor

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
    Process.send_after(self(), :connect_known_nodes, 5_000)

    # This node's own row is a database write. Made here it would hold up every
    # child started after this one, and an unreachable server raises rather
    # than returning, so a database a few seconds behind the app would take the
    # boot with it.
    #
    # Non-blocking, unlike Config.Loader: a node can run for a moment without
    # its row. The row says "this node is up", and it says so just as well a
    # second later.
    {:ok, %{}, {:continue, :register_self}}
  end

  @impl true
  def handle_continue(:register_self, state) do
    register(to_string(node()), 0)
    {:noreply, state}
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
    register(name, 0)
    {:noreply, state}
  end

  # A retry owed from either path. The count rides on the message rather than
  # sitting in the state, because this process registers many names and a
  # single shared counter makes one name's backoff depend on another's history.
  def handle_info({:register, name, attempts}, state) do
    register(name, attempts)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, remote_node}, state) do
    name = to_string(remote_node)
    Logger.info("Node disconnected: #{name}")
    guarded("marking #{name} disconnected", fn -> mark_disconnected(name) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect_known_nodes, state) do
    guarded("connecting to known nodes", &connect_known_nodes/0)
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

  defp mark_disconnected(name) do
    case AlexClaw.Cluster.get_by_name(name) do
      nil -> :ok
      node -> AlexClaw.Cluster.update_node(node, %{status: "disconnected"})
    end
  end

  defp connect_known_nodes do
    self_name = to_string(node())

    AlexClaw.Cluster.list_nodes()
    |> Enum.reject(fn n -> n.name == self_name end)
    |> Enum.each(fn n -> AlexClaw.Cluster.node_ping(n.name) end)
  end

  # This process answers RPC from other nodes and monitors the cluster, so a
  # database that has gone away must not take it down. Registration is retried
  # because the row is owed; these two are not, because the sixty-second
  # refresh writes the same statuses again shortly.
  #
  # Both of these were left unguarded when registration was fixed, reported as
  # out of scope, and then killed the process in CI — :connect_known_nodes
  # fires five seconds after boot, which is exactly when a database is least
  # likely to be there.
  defp guarded(what, fun) do
    fun.()
    :ok
  rescue
    e -> skipped(what, Exception.message(e))
  catch
    :exit, reason -> skipped(what, inspect(reason))
  end

  defp skipped(what, reason) do
    Logger.warning("Cluster manager skipped #{what}: #{reason}")
    :ok
  end

  # A node with no name has nothing to register: the VM is not distributed.
  defp register("nonode@nohost", _attempts), do: :ok
  defp register(name, attempts), do: settle(auto_register_node(name), name, attempts)

  defp settle(:ok, _name, _attempts), do: :ok

  defp settle({:error, reason}, name, attempts) do
    BootRetry.schedule({:register, name, attempts + 1}, attempts, "Cluster node #{name}", reason)
    :ok
  end

  # `:ok` means nothing more is owed — the row is there, or the attempt failed
  # in a way that trying again will not mend. `{:error, reason}` is the database
  # being unreachable, which is worth another go.
  #
  # Broad on purpose: every call in here is a database call, an unreachable
  # server raises DBConnection.ConnectionError, and a connection that goes away
  # exits rather than raising.
  defp auto_register_node(name) do
    case AlexClaw.Cluster.get_by_name(name) do
      nil -> create_node(name)
      existing -> touch_node(existing)
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp create_node(name) do
    label = name |> String.split("@") |> List.last()

    AlexClaw.Cluster.create_node(%{
      name: name,
      label: label,
      status: "connected",
      last_seen_at: DateTime.utc_now()
    })
    |> registered(name)
  end

  # A node that was already known is a heartbeat, not news, so it is not logged.
  defp touch_node(existing) do
    AlexClaw.Cluster.update_node(existing, %{
      status: "connected",
      last_seen_at: DateTime.utc_now()
    })

    :ok
  end

  defp registered({:ok, _node}, name) do
    Logger.info("Auto-registered cluster node: #{name}")
    :ok
  end

  # A changeset that will not validate is not a database that will be back in a
  # second, so this is not retried.
  defp registered({:error, _changeset}, name) do
    Logger.warning("Failed to auto-register node: #{name}")
    :ok
  end

  defp do_receive(workflow_name, data, source_node) do
    alias AlexClaw.Workflows.Workflow

    AlexClaw.Repo.one(
      from(w in Workflow,
        where: w.name == ^workflow_name and w.enabled == true,
        preload: [steps: ^from(s in AlexClaw.Workflows.WorkflowStep, order_by: s.position)]
      )
    )
    |> trigger_workflow(workflow_name, data, source_node)
  end

  defp trigger_workflow(nil, workflow_name, _data, _source_node) do
    Logger.warning("Remote trigger rejected: workflow '#{workflow_name}' not found or disabled")
    {:error, :workflow_not_found}
  end

  defp trigger_workflow(workflow, workflow_name, data, source_node) do
    gated? = match?(%{skill: "receive_from_workflow"}, List.first(workflow.steps))
    run_gated(gated?, workflow, workflow_name, data, source_node)
  end

  defp run_gated(false, _workflow, workflow_name, _data, _source_node) do
    Logger.warning("Remote trigger rejected: '#{workflow_name}' lacks receive_from_workflow gate")
    {:error, :no_receive_gate}
  end

  defp run_gated(true, workflow, workflow_name, data, source_node) do
    Logger.info("Remote trigger accepted: '#{workflow_name}' from #{source_node}")

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      Executor.run_with_input(workflow.id, data, %{"_source_node" => source_node})
    end)

    {:ok, :started}
  end
end
