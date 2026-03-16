defmodule AlexClaw.Config do
  @moduledoc """
  Runtime configuration system. DB-persisted, ETS-cached.
  Supports typed values (string, integer, float, boolean, json).
  Changes are broadcast via Phoenix.PubSub so LiveViews update in real time.
  """
  require Logger
  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Config.Setting

  @type config_value :: String.t() | integer() | float() | boolean() | map() | list() | nil
  @type set_opts :: [type: String.t(), description: String.t() | nil, category: String.t()]

  @table :alexclaw_config
  @pubsub AlexClaw.PubSub
  @topic "config:changes"

  # --- ETS lifecycle ---

  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> :ok
    end
    load_all_into_ets()
  end

  defp load_all_into_ets do
    case Repo.all(Setting) do
      entries when is_list(entries) ->
        Enum.each(entries, fn s -> :ets.insert(@table, {s.key, cast_value(s)}) end)

      _ ->
        :ok
    end
  catch
    :error, %Postgrex.Error{} = e ->
      Logger.warning("Settings table not ready: #{Exception.message(e)}")
      :ok
  end

  # --- Public API ---

  @doc "Get a config value. Returns default if not set."
  @spec get(String.t(), config_value()) :: config_value()
  def get(key, default \\ nil) do
    case :ets.lookup(@table, key) do
      [{_, value}] -> value
      [] -> default
    end
  end

  @doc "Set a config value. Persists to DB and updates ETS cache."
  @spec set(String.t(), config_value(), set_opts()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def set(key, value, opts \\ []) do
    type = Keyword.get(opts, :type, "string")
    description = Keyword.get(opts, :description)
    category = Keyword.get(opts, :category, "general")

    attrs = %{
      key: key,
      value: encode_value(value, type),
      type: type,
      description: description,
      category: category
    }

    result =
      case Repo.get_by(Setting, key: key) do
        nil -> %Setting{} |> Setting.changeset(attrs) |> Repo.insert()
        existing -> existing |> Setting.changeset(attrs) |> Repo.update()
      end

    case result do
      {:ok, setting} ->
        :ets.insert(@table, {key, cast_value(setting)})
        broadcast_change(key, cast_value(setting))
        {:ok, setting}

      error ->
        error
    end
  end

  @doc "Delete a config key."
  @spec delete(String.t()) :: :ok
  def delete(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> :ok
      setting -> Repo.delete(setting)
    end

    :ets.delete(@table, key)
    broadcast_change(key, nil)
    :ok
  end

  @doc "List all settings, optionally filtered by category."
  @spec list(String.t() | nil) :: [Setting.t()]
  def list(category \\ nil) do
    Setting
    |> maybe_filter_category(category)
    |> order_by(:key)
    |> Repo.all()
  end

  @doc "Subscribe to config changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # --- Value casting ---

  defp cast_value(%Setting{type: "integer", value: v}) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> 0
    end
  end
  defp cast_value(%Setting{type: "float", value: v}) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp cast_value(%Setting{type: "boolean", value: "true"}), do: true
  defp cast_value(%Setting{type: "boolean", value: _}), do: false
  defp cast_value(%Setting{type: "json", value: v}), do: Jason.decode!(v)
  defp cast_value(%Setting{value: v}), do: v

  defp encode_value(value, "json") when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp encode_value(value, _type), do: to_string(value)

  defp maybe_filter_category(q, nil), do: q
  defp maybe_filter_category(q, cat), do: where(q, [s], s.category == ^cat)

  defp broadcast_change(key, value) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:config_changed, key, value})
  end
end
