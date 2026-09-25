defmodule AlexClaw.Gateway.Telegram.Token do
  @moduledoc """
  The Telegram gateway's bot token, held in this process only.

  The gateway is a long-lived consumer: it resolves the token once
  (`AlexClaw.Config.secret/2`: binding checked, use audited) and keeps it here,
  instead of resolving — and writing an audit row — on every poll. It resolves
  again only when:

    * the secret is rotated or removed: `AlexClaw.Secrets` announces
      `{:secret_rotated, name}` (the name, never the value), and the time the
      value was last set, checked on every read, no longer matches;
    * Telegram answers 401: `invalidate/0`.

  While no token is set, nothing is resolved, so an unconfigured gateway writes
  no audit rows.
  """
  use GenServer

  require Logger

  alias AlexClaw.Config
  alias AlexClaw.Config.SecretSettings

  @key "telegram.bot_token"

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The token, or nil when none is set or it cannot be resolved."
  @spec get() :: String.t() | nil
  def get do
    GenServer.call(__MODULE__, :get)
  catch
    :exit, _reason -> nil
  end

  @doc "Drop the held token: Telegram refused it. The next `get/0` resolves again."
  @spec invalidate() :: :ok
  def invalidate, do: GenServer.cast(__MODULE__, :invalidate)

  @impl true
  def init(nil) do
    Phoenix.PubSub.subscribe(AlexClaw.PubSub, AlexClaw.Secrets.topic())
    {:ok, nil}
  end

  @impl true
  def handle_call(:get, _from, held) do
    held = current(Config.secret_set_at(@key), held)
    {:reply, token(held), held}
  end

  @impl true
  def handle_cast(:invalidate, _held), do: {:noreply, nil}

  @impl true
  def handle_info({:secret_rotated, name}, held) do
    if name == SecretSettings.secret_name(@key), do: {:noreply, nil}, else: {:noreply, held}
  end

  # Held as {token, when it was set}: kept while the setting's date matches.
  defp current(nil, _held), do: nil
  defp current(set_at, {_token, set_at} = held), do: held
  defp current(set_at, _stale), do: resolved(set_at)

  defp resolved(set_at) do
    case Config.secret(@key, for: Config.secret_binding(@key)) do
      {:ok, token} ->
        {token, set_at}

      {:error, reason} ->
        Logger.warning("Telegram bot token unavailable (#{reason})")
        nil
    end
  end

  defp token({token, _set_at}), do: token
  defp token(nil), do: nil
end
