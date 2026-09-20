defmodule AlexClaw.LLM.UsageTracker do
  @moduledoc """
  ETS owner process for LLM usage counters.
  Loads today's counts from PostgreSQL on startup (survives restarts).
  Writes through to DB on every increment.
  Resets ETS daily at midnight UTC.

  Usage keys are provider IDs (integers) — no more atom-based model names.
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias AlexClaw.BootRetry
  alias AlexClaw.LLM.UsageEntry
  alias AlexClaw.Repo

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    AlexClaw.LLM.init_usage_table()
    schedule_midnight_reset()

    # Today's counts come from the database. Read here, they would hold up every
    # child the supervisor starts after this one, and a database that is not up
    # yet would fail the boot rather than the read. handle_continue/2 runs
    # before any other message, so nothing observes a half-loaded table through
    # this process.
    {:ok, %{attempts: 0}, {:continue, :load_today}}
  end

  @impl true
  def handle_continue(:load_today, state), do: {:noreply, load_or_retry(state)}

  @impl true
  def handle_info(:load_today, state), do: {:noreply, load_or_retry(state)}

  @impl true
  def handle_info(:reset, state) do
    :ets.delete_all_objects(:alexclaw_llm_usage)
    Logger.info("LLM usage counters reset")
    schedule_midnight_reset()
    {:noreply, state}
  end

  @doc "Persist current ETS count for a provider to the database."
  @spec persist(integer()) :: :ok
  def persist(provider_id) when is_integer(provider_id) do
    today = Date.utc_today()
    key = {provider_id, today}

    count =
      case :ets.lookup(:alexclaw_llm_usage, key) do
        [{_, c}] -> c
        [] -> 0
      end

    model_str = "provider_#{provider_id}"

    Repo.insert!(
      %UsageEntry{model: model_str, date: today, count: count},
      on_conflict: [set: [count: count]],
      conflict_target: [:model, :date]
    )

    :ok
  end

  # Broad on purpose, and every failure mode in here is the database: an
  # unreachable server raises DBConnection.ConnectionError, a missing table
  # raises Postgrex.Error, and a connection that goes away exits. What used to
  # be here caught :error on a Postgrex.Error alone, so a database that was not
  # up yet went straight past it and killed the process.
  defp load_today_from_db do
    today = Date.utc_today()

    entries = Repo.all(from(u in UsageEntry, where: u.date == ^today))

    for %{model: model_str, count: count} <- entries do
      case parse_model_string(model_str) do
        {:ok, provider_id} ->
          key = {provider_id, today}
          :ets.insert(:alexclaw_llm_usage, {key, count})

        :skip ->
          :ok
      end
    end

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp load_or_retry(state), do: settle(load_today_from_db(), state)

  defp settle(:ok, state) do
    Logger.info("LLM UsageTracker loaded today's persisted counts")
    %{state | attempts: 0}
  end

  defp settle({:error, reason}, state) do
    %{state | attempts: BootRetry.schedule(:load_today, state.attempts, "Usage counts", reason)}
  end

  # Parse both new "provider_<id>" and legacy formats
  defp parse_model_string("provider_" <> id_str) do
    case Integer.parse(id_str) do
      {id, ""} -> {:ok, id}
      _ -> :skip
    end
  end

  # Legacy: "custom_<id>" — these map to the same provider IDs
  defp parse_model_string("custom_" <> id_str) do
    case Integer.parse(id_str) do
      {id, ""} -> {:ok, id}
      _ -> :skip
    end
  end

  # Legacy atom-based entries (e.g. "gemini_flash", "lm_studio") — look up by name mapping
  defp parse_model_string(legacy_str) do
    name = legacy_name_to_provider_name(legacy_str)

    case AlexClaw.Repo.one(from(p in AlexClaw.LLM.Provider, where: p.name == ^name, select: p.id)) do
      nil -> :skip
      id -> {:ok, id}
    end
  end

  defp legacy_name_to_provider_name("gemini_flash"), do: "Gemini Flash"
  defp legacy_name_to_provider_name("gemini_pro"), do: "Gemini Pro"
  defp legacy_name_to_provider_name("haiku"), do: "Claude Haiku"
  defp legacy_name_to_provider_name("sonnet"), do: "Claude Sonnet"
  defp legacy_name_to_provider_name("opus"), do: "Claude Opus"
  defp legacy_name_to_provider_name("ollama"), do: "Ollama"
  defp legacy_name_to_provider_name("lm_studio"), do: "LM Studio"
  defp legacy_name_to_provider_name(other), do: other

  defp schedule_midnight_reset do
    now = DateTime.utc_now()
    tomorrow = Date.add(Date.utc_today(), 1)
    midnight = DateTime.new!(tomorrow, ~T[00:00:00], "Etc/UTC")
    ms = DateTime.diff(midnight, now, :millisecond)
    Process.send_after(self(), :reset, ms)
  end
end
