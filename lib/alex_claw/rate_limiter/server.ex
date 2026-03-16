defmodule AlexClaw.RateLimiter.Server do
  @moduledoc """
  GenServer that owns the rate limiter ETS table and runs periodic cleanup.
  """
  use GenServer
  require Logger

  @purge_interval_ms 60_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    AlexClaw.RateLimiter.init_table()
    schedule_purge()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:purge, state) do
    count = AlexClaw.RateLimiter.purge_expired()
    if count > 0, do: Logger.debug("RateLimiter: purged #{count} expired entries")
    schedule_purge()
    {:noreply, state}
  end

  defp schedule_purge do
    Process.send_after(self(), :purge, @purge_interval_ms)
  end
end
