defmodule AlexClaw.Gateway.Supervisor do
  @moduledoc """
  Supervises the chat gateways, so their restarts count here and not against
  the application's root supervisor.

  A gateway that keeps crashing uses up this supervisor's restart intensity;
  the root then restarts this supervisor, once, and nothing else. Directly
  under the root, four Telegram crashes in three seconds stopped the whole
  application (2026-09-23).

  The Discord starter follows `:start_background_workers`, as it did at the
  root: the test environment starts the Telegram gateway only.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(
      [AlexClaw.Gateway.Telegram.Token, AlexClaw.Gateway.Telegram | discord_children()],
      strategy: :one_for_one
    )
  end

  defp discord_children do
    :alex_claw
    |> Application.get_env(:start_background_workers, true)
    |> discord_children()
  end

  defp discord_children(true), do: [AlexClaw.Gateway.DiscordStarter]
  defp discord_children(false), do: []
end
