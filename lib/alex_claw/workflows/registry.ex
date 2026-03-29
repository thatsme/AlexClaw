defmodule AlexClaw.Workflows.Registry do
  @moduledoc """
  Tracks running workflow processes via GenServer + ETS.
  Enables listing active runs, cancellation, and crash cleanup.
  """
  use GenServer
  require Logger

  alias AlexClaw.Workflows

  @ets_table :workflow_registry
  @pubsub_topic "workflows:runs"

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(integer(), pid(), integer(), String.t()) :: :ok
  def register(run_id, pid, workflow_id, workflow_name) do
    GenServer.call(__MODULE__, {:register, run_id, pid, workflow_id, workflow_name})
  end

  @spec deregister(integer()) :: :ok
  def deregister(run_id) do
    GenServer.call(__MODULE__, {:deregister, run_id})
  end

  @spec list_active() :: [map()]
  def list_active do
    Enum.map(:ets.tab2list(@ets_table), &row_to_map/1)
  end

  @spec lookup(integer()) :: {:ok, map()} | {:error, :not_found}
  def lookup(run_id) do
    case :ets.lookup(@ets_table, run_id) do
      [row] -> {:ok, row_to_map(row)}
      [] -> {:error, :not_found}
    end
  end

  defp row_to_map({run_id, _pid, workflow_id, workflow_name, started_at}) do
    %{run_id: run_id, workflow_id: workflow_id, workflow_name: workflow_name, started_at: started_at, current_step: nil}
  end

  defp row_to_map({run_id, _pid, workflow_id, workflow_name, started_at, step_name}) do
    %{run_id: run_id, workflow_id: workflow_id, workflow_name: workflow_name, started_at: started_at, current_step: step_name}
  end

  @spec update_step(integer(), String.t()) :: :ok
  def update_step(run_id, step_name) do
    case :ets.lookup(@ets_table, run_id) do
      [row] ->
        :ets.insert(@ets_table, {run_id, elem(row, 1), elem(row, 2), elem(row, 3), elem(row, 4), step_name})
        :ok

      _ ->
        :ok
    end
  end

  @spec cancel(integer()) :: :ok | {:error, :not_found}
  def cancel(run_id) do
    GenServer.call(__MODULE__, {:cancel, run_id})
  end

  @spec broadcast(tuple()) :: :ok | {:error, term()}
  def broadcast(message) do
    Phoenix.PubSub.broadcast(AlexClaw.PubSub, @pubsub_topic, message)
  end

  @spec topic() :: String.t()
  def topic, do: @pubsub_topic

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{table: table, monitors: %{}}}
  end

  @impl true
  def handle_call({:register, run_id, pid, workflow_id, workflow_name}, _from, state) do
    ref = Process.monitor(pid)
    :ets.insert(@ets_table, {run_id, pid, workflow_id, workflow_name, DateTime.utc_now()})
    monitors = Map.put(state.monitors, ref, run_id)
    {:reply, :ok, %{state | monitors: monitors}}
  end

  def handle_call({:cancel, run_id}, _from, state) do
    case :ets.lookup(@ets_table, run_id) do
      [row] when elem(row, 0) == run_id ->
        pid = elem(row, 1)
        workflow_id = elem(row, 2)
        workflow_name = elem(row, 3)

        case Workflows.get_run(run_id) do
          {:ok, run} ->
            Workflows.update_run(run, %{status: "cancelled", completed_at: DateTime.utc_now()})

          _ ->
            :ok
        end

        :ets.delete(@ets_table, run_id)

        {ref, monitors} =
          Enum.reduce(state.monitors, {nil, state.monitors}, fn {r, rid}, {found, acc} ->
            if rid == run_id, do: {r, Map.delete(acc, r)}, else: {found, acc}
          end)

        if ref, do: Process.demonitor(ref, [:flush])

        Process.exit(pid, :cancelled)

        broadcast({:workflow_run_cancelled, %{run_id: run_id, workflow_id: workflow_id, workflow_name: workflow_name}})
        Logger.info("[WorkflowRegistry] Cancelled run #{run_id} (#{workflow_name})")

        {:reply, :ok, %{state | monitors: monitors}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:deregister, run_id}, _from, state) do
    :ets.delete(@ets_table, run_id)

    {ref, monitors} =
      Enum.reduce(state.monitors, {nil, state.monitors}, fn {r, rid}, {found, acc} ->
        if rid == run_id, do: {r, Map.delete(acc, r)}, else: {found, acc}
      end)

    if ref, do: Process.demonitor(ref, [:flush])

    {:reply, :ok, %{state | monitors: monitors}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {run_id, monitors} ->
        :ets.delete(@ets_table, run_id)

        unless reason in [:normal, :cancelled] do
          case Workflows.get_run(run_id) do
            {:ok, %{status: "running"} = run} ->
              Workflows.update_run(run, %{
                status: "failed",
                completed_at: DateTime.utc_now(),
                error: "Process crashed: #{inspect(reason)}"
              })

              Logger.warning("[WorkflowRegistry] Run #{run_id} crashed: #{inspect(reason)}")

            _ ->
              :ok
          end
        end

        {:noreply, %{state | monitors: monitors}}
    end
  end
end
