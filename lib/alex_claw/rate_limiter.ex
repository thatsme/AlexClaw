defmodule AlexClaw.RateLimiter do
  @moduledoc """
  ETS-based rate limiter for login attempts.
  Tracks failed attempts per IP. Blocks after max_attempts for block_duration_seconds.
  Table is owned by AlexClaw.RateLimiter.Server GenServer.
  """

  @table :alexclaw_rate_limiter

  # --- Public API ---

  @doc "Check if the IP is currently blocked. Returns :ok or {:error, :rate_limited, seconds_remaining}."
  @spec check(String.t()) :: :ok | {:error, :rate_limited, integer()}
  def check(ip) do
    max = max_attempts()
    now = System.system_time(:second)

    case :ets.lookup(@table, ip) do
      [] ->
        :ok

      [{^ip, _attempts, blocked_until}] when not is_nil(blocked_until) ->
        if now < blocked_until do
          {:error, :rate_limited, blocked_until - now}
        else
          :ets.delete(@table, ip)
          :ok
        end

      [{^ip, attempts, nil}] when attempts >= max ->
        blocked_until = now + block_duration()
        :ets.insert(@table, {ip, attempts, blocked_until})
        {:error, :rate_limited, block_duration()}

      _ ->
        :ok
    end
  end

  @doc "Record a failed login attempt for the IP."
  @spec record_failure(String.t()) :: :ok
  def record_failure(ip) do
    case :ets.lookup(@table, ip) do
      [] ->
        :ets.insert(@table, {ip, 1, nil})

      [{^ip, attempts, nil}] ->
        :ets.insert(@table, {ip, attempts + 1, nil})

      [{^ip, _attempts, _blocked_until}] ->
        now = System.system_time(:second)
        :ets.insert(@table, {ip, max_attempts(), now + block_duration()})
    end

    :ok
  end

  @doc "Clear rate limit record for an IP (on successful login)."
  @spec clear(String.t()) :: :ok
  def clear(ip) do
    :ets.delete(@table, ip)
    :ok
  end

  @doc "Initialize ETS table. Called by Server on start."
  @spec init_table() :: :ok
  def init_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set])

      _ ->
        :ok
    end

    :ok
  end

  @doc "Purge expired entries. Called periodically by Server."
  @spec purge_expired() :: integer()
  def purge_expired do
    now = System.system_time(:second)

    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn
        {_ip, _attempts, blocked_until} when not is_nil(blocked_until) ->
          now >= blocked_until

        _ ->
          false
      end)
      |> Enum.map(fn {ip, _, _} -> ip end)

    Enum.each(expired, &:ets.delete(@table, &1))
    length(expired)
  end

  # --- Config helpers ---

  defp max_attempts, do: AlexClaw.Config.get("auth.rate_limit.max_attempts", 5)
  defp block_duration, do: AlexClaw.Config.get("auth.rate_limit.block_duration_seconds", 900)
end
