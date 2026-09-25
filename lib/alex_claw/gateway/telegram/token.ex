defmodule AlexClaw.Gateway.Telegram.Token do
  @moduledoc """
  The Telegram gateway's bot token, held in its own process
  (`AlexClaw.Config.HeldSecret`): resolved once, and again only after a
  rotation or a 401 from Telegram (`invalidate/0`).
  """

  alias AlexClaw.Config.HeldSecret

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts), do: HeldSecret.child_spec(key: "telegram.bot_token", name: __MODULE__)

  @doc "The token, or nil when none is set or it cannot be resolved."
  @spec get() :: String.t() | nil
  def get, do: HeldSecret.get(__MODULE__)

  @doc "Drop the held token: Telegram refused it. The next `get/0` resolves again."
  @spec invalidate() :: :ok
  def invalidate, do: HeldSecret.invalidate(__MODULE__)
end
