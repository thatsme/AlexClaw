defmodule AlexClaw.Config.HeldSecret do
  @moduledoc """
  A long-lived consumer's secret setting, resolved once and held in a process of
  its own.

  A gateway or an inbound endpoint uses its secret on every poll or request.
  Resolving each time (`AlexClaw.Config.secret/2`: binding checked, use
  audited) would write an audit row per use, so the consumer holds it here
  instead, and it is resolved again only when:

    * the secret is rotated or removed: `AlexClaw.Secrets` announces
      `{:secret_rotated, name}` (the name, never the value), and the time the
      value was last set, checked on every read, no longer matches;
    * the consumer is told the value is refused (a 401): `invalidate/1`.

  While no value is set, nothing is resolved, so an unconfigured consumer writes
  no audit rows.

  Started with `key:` (the setting), `name:` (how the consumer addresses it),
  and optionally `for:` (the destination; by default the key's one binding).
  """
  use GenServer

  require Logger

  alias AlexClaw.Config
  alias AlexClaw.Config.SecretSettings

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    conf = %{key: Keyword.fetch!(opts, :key), for: Keyword.get(opts, :for)}
    GenServer.start_link(__MODULE__, conf, name: Keyword.fetch!(opts, :name))
  end

  @doc "The value, or nil when none is set or it cannot be resolved."
  @spec get(GenServer.server()) :: String.t() | nil
  def get(server) do
    GenServer.call(server, :get)
  catch
    :exit, _reason -> nil
  end

  @doc "Drop the held value: it was refused. The next `get/1` resolves again."
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server), do: GenServer.cast(server, :invalidate)

  @impl true
  def init(conf) do
    Phoenix.PubSub.subscribe(AlexClaw.PubSub, AlexClaw.Secrets.topic())
    {:ok, Map.put(conf, :held, nil)}
  end

  # A crash report or :sys.get_status/1 shows the state: never the value held
  # (S8 M13).
  @impl true
  def format_status(status), do: Map.update(status, :state, nil, &hidden_value/1)

  defp hidden_value(%{held: {_value, set_at}} = state), do: %{state | held: {:redacted, set_at}}
  defp hidden_value(state), do: state

  @impl true
  def handle_call(:get, _from, state) do
    held = current(Config.secret_set_at(state.key), state.held, state)
    {:reply, value(held), %{state | held: held}}
  end

  @impl true
  def handle_cast(:invalidate, state), do: {:noreply, %{state | held: nil}}

  @impl true
  def handle_info({:secret_rotated, name}, state) do
    if name == SecretSettings.secret_name(state.key),
      do: {:noreply, %{state | held: nil}},
      else: {:noreply, state}
  end

  # Held as {value, when it was set}: kept while the setting's date matches.
  defp current(nil, _held, _state), do: nil
  defp current(set_at, {_value, set_at} = held, _state), do: held
  defp current(set_at, _stale, state), do: resolved(set_at, state)

  defp resolved(set_at, %{key: key} = state) do
    case Config.secret(key, for: destination(state)) do
      {:ok, value} ->
        {value, set_at}

      {:error, reason} ->
        Logger.warning("#{key} unavailable (#{reason})")
        nil
    end
  end

  defp destination(%{for: nil, key: key}), do: Config.secret_binding(key)
  defp destination(%{for: destination}), do: destination

  defp value({value, _set_at}), do: value
  defp value(nil), do: nil
end
