defmodule AlexClaw.RateLimiter do
  @moduledoc """
  ETS-based rate limiter for login attempts.
  Tracks failed attempts per IP within a sliding window. Blocks after
  max_attempts failures inside window_seconds, for block_duration_seconds.
  Failures older than the window are discarded rather than accumulating.
  Table is owned by AlexClaw.RateLimiter.Server GenServer.
  """

  @table :alexclaw_rate_limiter

  # --- Public API ---

  @doc "Check if the IP is currently blocked. Returns :ok or {:error, :rate_limited, seconds_remaining}."
  @spec check(String.t()) :: :ok | {:error, :rate_limited, integer()}
  def check(ip) do
    now = System.system_time(:second)

    case :ets.lookup(@table, ip) do
      [] ->
        :ok

      [{^ip, _attempts, blocked_until, _first}] when is_integer(blocked_until) ->
        still_blocked(ip, blocked_until, now)

      [{^ip, attempts, nil, first}] ->
        count_within_window(ip, attempts, now, now - first < window_seconds())
    end
  end

  defp still_blocked(_ip, blocked_until, now) when now < blocked_until,
    do: {:error, :rate_limited, blocked_until - now}

  defp still_blocked(ip, _blocked_until, _now) do
    :ets.delete(@table, ip)
    :ok
  end

  # Outside the window the count is stale: it is dropped rather than left to
  # accumulate, so an IP is never one failure away from a block indefinitely.
  defp count_within_window(ip, _attempts, _now, false) do
    :ets.delete(@table, ip)
    :ok
  end

  defp count_within_window(ip, attempts, now, true),
    do: block_if_over(ip, attempts, now, max_attempts())

  defp block_if_over(ip, attempts, now, max) when attempts >= max do
    blocked_until = now + block_duration()
    :ets.insert(@table, {ip, attempts, blocked_until, now})
    {:error, :rate_limited, block_duration()}
  end

  defp block_if_over(_ip, _attempts, _now, _max), do: :ok

  @doc "Record a failed login attempt for the IP."
  @spec record_failure(String.t()) :: :ok
  def record_failure(ip) do
    now = System.system_time(:second)

    case :ets.lookup(@table, ip) do
      [] ->
        :ets.insert(@table, {ip, 1, nil, now})

      [{^ip, attempts, nil, first}] ->
        :ets.insert(@table, counted(ip, attempts, first, now, now - first < window_seconds()))

      [{^ip, _attempts, _blocked_until, _first}] ->
        :ets.insert(@table, {ip, max_attempts(), now + block_duration(), now})
    end

    :ok
  end

  # A failure arriving after the window has passed starts a fresh count.
  defp counted(ip, attempts, first, _now, true), do: {ip, attempts + 1, nil, first}
  defp counted(ip, _attempts, _first, now, false), do: {ip, 1, nil, now}

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
    window = window_seconds()

    expired =
      @table
      |> :ets.tab2list()
      |> Enum.filter(&expired?(&1, now, window))
      |> Enum.map(fn {ip, _, _, _} -> ip end)

    Enum.each(expired, &:ets.delete(@table, &1))
    length(expired)
  end

  defp expired?({_ip, _attempts, blocked_until, _first}, now, _window)
       when is_integer(blocked_until),
       do: now >= blocked_until

  defp expired?({_ip, _attempts, nil, first}, now, window), do: now - first >= window

  # --- Config helpers ---

  defp max_attempts, do: AlexClaw.Config.get("auth.rate_limit.max_attempts", 5)
  defp block_duration, do: AlexClaw.Config.get("auth.rate_limit.block_duration_seconds", 900)
  defp window_seconds, do: AlexClaw.Config.get("auth.rate_limit.window_seconds", 300)
end
