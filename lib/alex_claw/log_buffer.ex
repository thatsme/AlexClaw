defmodule AlexClaw.LogBuffer do
  @moduledoc """
  In-memory ring buffer for application logs. Attaches to Elixir's Logger
  and stores the most recent entries in ETS for display in the admin UI.

  Each log entry is classified into a severity tier:
  - :critical — missing required config, DB connection failures
  - :high — LLM/Telegram failures, skill crashes
  - :moderate — warnings, retries, rate limits
  - :low — informational messages
  """
  use GenServer

  @table :alexclaw_log_buffer
  @max_entries 500
  @counter_key :log_counter

  # --- Client API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Return recent log entries, optionally filtered by severity."
  @spec recent(keyword()) :: [map()]
  def recent(opts \\ []) do
    severity = Keyword.get(opts, :severity)
    limit = Keyword.get(opts, :limit, 100)

    entries =
      @table
      |> :ets.tab2list()
      |> Enum.reject(fn {k, _} -> k == @counter_key end)
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.sort_by(& &1.id, :desc)

    entries =
      if severity do
        Enum.filter(entries, &(&1.severity == severity))
      else
        entries
      end

    Enum.take(entries, limit)
  end

  @doc "Clear all log entries."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ets.insert(@table, {@counter_key, 0})
    :ok
  end

  @doc "Return counts per severity."
  @spec counts() :: %{critical: non_neg_integer(), high: non_neg_integer(), moderate: non_neg_integer(), low: non_neg_integer(), circuit_breaker: non_neg_integer()}
  def counts do
    entries =
      @table
      |> :ets.tab2list()
      |> Enum.reject(fn {k, _} -> k == @counter_key end)
      |> Enum.map(fn {_id, entry} -> entry.severity end)

    %{
      critical: Enum.count(entries, &(&1 == :critical)),
      high: Enum.count(entries, &(&1 == :high)),
      moderate: Enum.count(entries, &(&1 == :moderate)),
      low: Enum.count(entries, &(&1 == :low)),
      circuit_breaker: Enum.count(entries, &(&1 == :circuit_breaker))
    }
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    :ets.insert(@table, {@counter_key, 0})

    :logger.add_handler(:alexclaw_log_buffer, __MODULE__, %{})

    {:ok, %{}}
  end

  # --- :logger handler callbacks (Erlang logger API) ---

  @doc false
  def adding_handler(config), do: {:ok, config}

  @doc false
  def removing_handler(_config), do: :ok

  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    message = format_message(msg)

    unless skip?(message, meta) do
      severity = classify(level, message)
      id = :ets.update_counter(@table, @counter_key, {2, 1})

      entry = %{
        id: id,
        level: level,
        severity: severity,
        message: message,
        module: Map.get(meta, :module),
        workflow: Map.get(meta, :workflow),
        timestamp: DateTime.utc_now(),
        domain: Map.get(meta, :domain, [])
      }

      :ets.insert(@table, {id, entry})
      maybe_evict(id)
    end
  end

  # --- Internals ---

  defp format_message({:string, msg}), do: IO.iodata_to_binary(msg)
  defp format_message({:report, report}), do: inspect(report)
  defp format_message(msg) when is_binary(msg), do: msg
  defp format_message(msg), do: inspect(msg)

  defp skip?(message, meta) do
    domain = Map.get(meta, :domain, [])

    # Skip OTP supervisor verbose reports, Ecto query logs, and Phoenix request logs.
    # Do NOT skip :elixir domain — that's where all application Logger calls live.
    :otp in domain or
      :ecto in domain or
      String.contains?(message, "GET /") or
      String.contains?(message, "POST /") or
      String.contains?(message, "PUT /") or
      String.contains?(message, "DELETE /") or
      String.contains?(message, "QUERY OK") or
      String.contains?(message, "CONNECTED TO Phoenix")
  end

  defp classify(level, message) do
    cond do
      circuit_breaker_pattern?(message) -> :circuit_breaker
      level == :emergency or level == :alert -> :critical
      level == :critical -> :critical
      level == :error and critical_pattern?(message) -> :critical
      level == :error -> :high
      level == :warning and high_pattern?(message) -> :high
      level == :warning -> :moderate
      true -> :low
    end
  end

  defp circuit_breaker_pattern?(msg) do
    String.contains?(msg, "[CircuitBreaker]")
  end

  defp critical_pattern?(msg) do
    String.contains?(msg, "not configured") or
      String.contains?(msg, "connection refused") or
      String.contains?(msg, "nxdomain") or
      String.contains?(msg, "database")
  end

  defp high_pattern?(msg) do
    String.contains?(msg, "No available model") or
      String.contains?(msg, "Cannot send") or
      String.contains?(msg, "failed")
  end

  defp maybe_evict(current_id) when current_id > @max_entries do
    evict_id = current_id - @max_entries
    :ets.delete(@table, evict_id)
  end

  defp maybe_evict(_), do: :ok
end
