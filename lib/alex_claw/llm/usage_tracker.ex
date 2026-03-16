defmodule AlexClaw.LLM.UsageTracker do
  @moduledoc """
  ETS owner process for LLM usage counters.
  Loads today's counts from PostgreSQL on startup (survives restarts).
  Writes through to DB on every increment.
  Resets ETS daily at midnight UTC.
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias AlexClaw.LLM.UsageEntry
  alias AlexClaw.Repo

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    AlexClaw.LLM.init_usage_table()
    load_today_from_db()
    schedule_midnight_reset()
    Logger.info("LLM UsageTracker started (loaded persisted counts)")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reset, state) do
    :ets.delete_all_objects(:alexclaw_llm_usage)
    Logger.info("LLM usage counters reset")
    schedule_midnight_reset()
    {:noreply, state}
  end

  @doc "Persist current ETS count for a model to the database."
  @spec persist(atom()) :: :ok
  def persist(model) do
    today = Date.utc_today()
    key = {model, today}

    count =
      case :ets.lookup(:alexclaw_llm_usage, key) do
        [{_, c}] -> c
        [] -> 0
      end

    model_str = model_to_string(model)

    Repo.insert!(
      %UsageEntry{model: model_str, date: today, count: count},
      on_conflict: [set: [count: count]],
      conflict_target: [:model, :date]
    )

    :ok
  end

  # Load today's persisted counts from DB into ETS so restarts don't zero them.
  defp load_today_from_db do
    today = Date.utc_today()

    entries =
      from(u in UsageEntry, where: u.date == ^today)
      |> Repo.all()

    for %{model: model_str, count: count} <- entries do
      model = string_to_model(model_str)
      key = {model, today}
      :ets.insert(:alexclaw_llm_usage, {key, count})
    end
  catch
    :error, %Postgrex.Error{} = e ->
      Logger.warning("Could not load usage from DB: #{Exception.message(e)}")
  end

  defp model_to_string({:custom, id}), do: "custom_#{id}"
  defp model_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp string_to_model("custom_" <> id_str) do
    case Integer.parse(id_str) do
      {id, ""} -> {:custom, id}
      _ -> String.to_existing_atom("custom_#{id_str}")
    end
  end

  defp string_to_model(model_str), do: String.to_existing_atom(model_str)

  defp schedule_midnight_reset do
    now = DateTime.utc_now()
    tomorrow = Date.add(Date.utc_today(), 1)
    midnight = DateTime.new!(tomorrow, ~T[00:00:00], "Etc/UTC")
    ms = DateTime.diff(midnight, now, :millisecond)
    Process.send_after(self(), :reset, ms)
  end
end
