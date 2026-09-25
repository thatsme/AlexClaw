defmodule AlexClaw.Cluster.Manager do
  @moduledoc """
  GenServer that manages cluster connectivity and handles incoming
  remote workflow triggers from other BEAM nodes.

  Called by `send_to_workflow` on another node with a GenServer call to this
  manager; the sender is the node of the calling process, never a name the
  request carries. A request
  is `:run_workflow` from the `:cluster` entry point, through
  `AlexClaw.ControlPlane.perform/3`: refused, and audited, unless the node is
  registered, the workflow's step 1 is the `receive_from_workflow` gate
  allowing it, and the workflow is not protected — before any run starts.

  A node that connects is not registered by connecting (it needs only the
  cookie): its arrival is audited, and it is registered in the admin UI
  (`save_node`). This node registers its own row at boot, and tries the
  known nodes.
  """
  use GenServer
  require Logger

  alias AlexClaw.Auth.AuditLog
  alias AlexClaw.{BootRetry, Cluster, ControlPlane, Repo}
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Workflows.Workflow

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ask this node to run the workflow `workflow_name` with `data`, as the node
  the calling process runs on — from another node, `send_to_workflow` calls
  `{AlexClaw.Cluster.Manager, node}` directly.
  """
  @spec receive_workflow_data(String.t(), any()) :: {:ok, :started} | {:error, atom() | tuple()}
  def receive_workflow_data(workflow_name, data) do
    GenServer.call(__MODULE__, {:receive, workflow_name, data}, 10_000)
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
  # The sender is the node the calling process runs on.
  def handle_call({:receive, workflow_name, data}, {caller, _tag}, state) do
    {:reply, request(workflow_named(workflow_name), data, node(caller)), state}
  end

  @impl true
  def handle_info({:nodeup, remote_node}, state) do
    name = to_string(remote_node)
    Logger.info("Node connected: #{name}")

    guarded("noting #{name}'s arrival", fn ->
      arrived(Cluster.mark_status(name, "connected"), name)
    end)

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
      Cluster.refresh_statuses()
    end)

    {:noreply, state}
  end

  # --- Internal ---

  defp mark_disconnected(name), do: Cluster.mark_status(name, "disconnected")

  # A registered node's arrival is a heartbeat. Any other node only has the
  # cookie: it is not registered by connecting, and the log says it came.
  defp arrived({:ok, _node}, _name), do: :ok

  defp arrived({:error, :not_registered}, name) do
    AuditLog.log_action_refusal(
      "cluster:#{name}",
      :cluster,
      :save_node,
      "node #{name} connected but is not registered — register it in the admin UI (Cluster page)"
    )
  end

  defp arrived({:error, _changeset}, _name), do: :ok

  defp connect_known_nodes do
    self_name = to_string(node())

    Cluster.list_nodes()
    |> Enum.reject(fn n -> n.name == self_name end)
    |> Enum.each(fn n -> Cluster.node_ping(n.name) end)
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
    name |> Cluster.register_self() |> registered(name)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp registered({:ok, :created}, name) do
    Logger.info("Registered this node: #{name}")
    :ok
  end

  # Already known: a heartbeat, not news, so it is not logged.
  defp registered({:ok, :touched}, _name), do: :ok

  # A changeset that will not validate is not a database that will be back in a
  # second, so this is not retried.
  defp registered({:error, _changeset}, name) do
    Logger.warning("Failed to auto-register node: #{name}")
    :ok
  end

  defp workflow_named(name), do: Repo.get_by(Workflow, name: name, enabled: true)

  defp request(nil, _data, _source_node), do: {:error, :workflow_not_found}

  defp request(workflow, data, source_node) do
    :run_workflow
    |> ControlPlane.perform(
      %{workflow_id: workflow.id, input: data},
      Context.cluster(source_node)
    )
    |> requested(workflow.name, source_node)
  end

  defp requested({:ok, _started}, name, source_node) do
    Logger.info("Remote trigger accepted: '#{name}' from #{source_node}")
    {:ok, :started}
  end

  defp requested({:error, reason} = refused, name, source_node) do
    Logger.warning("Remote trigger refused: '#{name}' from #{source_node}: #{inspect(reason)}")
    refused
  end
end
