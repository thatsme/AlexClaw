defmodule AlexClaw.Webhooks.GitHubSecret do
  @moduledoc """
  The GitHub webhook secret, held in its own process
  (`AlexClaw.Config.HeldSecret`): resolved once for `inbound:github_webhook`,
  and again only after it is rotated or removed. Checking a delivery's
  signature therefore writes no audit row per request.
  """

  alias AlexClaw.Config.HeldSecret

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts),
    do: HeldSecret.child_spec(key: "github.webhook_secret", name: __MODULE__)

  @doc "The secret, or nil when none is set or it cannot be resolved."
  @spec get() :: String.t() | nil
  def get, do: HeldSecret.get(__MODULE__)
end
