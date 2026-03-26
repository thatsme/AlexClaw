defmodule AlexClaw.Auth.SkillRateLimiter do
  @moduledoc """
  ETS-based per-skill, per-permission rate limiting.

  Tracks call counts in sliding windows. Used by PolicyEngine
  to enforce rate_limit policy rules.
  """
  use GenServer

  @table :auth_skill_rate_limiter
  @cleanup_interval :timer.seconds(60)

  # --- Public API ---

  @doc "Check if the call is within rate limits. Returns :ok or {:error, :rate_limited}."
  @spec check(String.t(), atom(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :rate_limited}
  def check(caller_key, permission, max_calls, window_seconds) do
    now = System.system_time(:second)
    key = {caller_key, permission}
    window_start = now - window_seconds

    case :ets.lookup(@table, key) do
      [{^key, timestamps}] ->
        recent = Enum.filter(timestamps, &(&1 >= window_start))

        if length(recent) >= max_calls do
          {:error, :rate_limited}
        else
          :ets.insert(@table, {key, [now | recent]})
          :ok
        end

      [] ->
        :ets.insert(@table, {key, [now]})
        :ok
    end
  end

  # --- GenServer (table owner + cleanup) ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    max_age = 300

    Enum.each(:ets.tab2list(@table), fn {key, timestamps} ->
      recent = Enum.filter(timestamps, &(&1 >= now - max_age))

      if recent == [] do
        :ets.delete(@table, key)
      else
        :ets.insert(@table, {key, recent})
      end
    end)

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
