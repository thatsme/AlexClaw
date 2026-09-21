defmodule AlexClaw.Auth.AuditLoss do
  @moduledoc """
  An audit row that could not be written is never silent.

  Every loss is logged at error level, in the caller, with the whole event —
  the log then holds what the table does not. The operator is also told over
  the gateways, but not once per row: a database that has gone away fails
  every audited action, and a notice for each would bury the one that matters.

  So the first loss is announced at once, and the losses after it are counted
  and announced together, at most once per interval, until an interval passes
  with none. That is two states — idle, and holding back — and this is the
  machine that moves between them.

  The caller only casts. Sending the notice is a supervised task, so a slow
  gateway holds up neither the audited action nor this process.
  """
  @behaviour :gen_statem

  require Logger

  alias AlexClaw.Gateway.Router

  @interval :timer.minutes(1)

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Start the notifier. `:interval` is in milliseconds; `:name` defaults to this module."
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    :gen_statem.start_link(
      {:local, name},
      __MODULE__,
      Keyword.get(opts, :interval, @interval),
      []
    )
  end

  @doc """
  Record that `entry` could not be written, and why.

  Logs at error level with the full event before anything else, so a notifier
  that is not running loses the notice and never the record.
  """
  @spec lost(map(), term(), :gen_statem.server_ref()) :: :ok
  def lost(entry, reason, server \\ __MODULE__) do
    Logger.error(
      "Audit row lost: #{inspect(reason)} — " <>
        inspect(entry, limit: :infinity, printable_limit: :infinity)
    )

    :gen_statem.cast(server, :lost)
  end

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(interval), do: {:ok, :idle, %{interval: interval, held: 0}}

  @impl :gen_statem
  def handle_event(:cast, :lost, :idle, data) do
    announce(1)
    {:next_state, :holding, data, [{:state_timeout, data.interval, :flush}]}
  end

  def handle_event(:cast, :lost, :holding, data) do
    {:keep_state, %{data | held: data.held + 1}}
  end

  def handle_event(:state_timeout, :flush, :holding, %{held: 0} = data) do
    {:next_state, :idle, data}
  end

  def handle_event(:state_timeout, :flush, :holding, data) do
    announce(data.held)
    {:keep_state, %{data | held: 0}, [{:state_timeout, data.interval, :flush}]}
  end

  defp announce(count) do
    {:ok, _pid} =
      Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
        Router.broadcast(notice(count))
      end)
  end

  defp notice(1) do
    "⚠️ An audit row could not be written. The event is in the error log " <>
      "(\"Audit row lost\")."
  end

  defp notice(count) do
    "⚠️ #{count} more audit rows could not be written. The events are in the " <>
      "error log (\"Audit row lost\")."
  end
end
