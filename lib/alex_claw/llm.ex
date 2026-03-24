defmodule AlexClaw.LLM do
  @moduledoc """
  Multi-model LLM router. All providers live in the database.
  Routes calls to the cheapest available provider that satisfies the
  requested reasoning tier. Tracks daily usage in ETS.
  """
  require Logger
  import Ecto.Query

  alias AlexClaw.LLM.{Client, Provider}

  @type tier :: :light | :medium | :heavy | :local
  @type complete_opts :: [tier: tier(), system: String.t() | nil]
  @type llm_result :: {:ok, String.t()} | {:error, term()}

  # --- Provider CRUD ---

  @doc "List all LLM providers, ordered by tier and priority."
  @spec list_providers() :: [Provider.t()]
  def list_providers do
    AlexClaw.Repo.all(from(p in Provider, order_by: [p.tier, p.priority, p.name]))
  end

  @doc "Fetch a provider by ID. Returns `{:ok, provider}` or `{:error, :not_found}`."
  @spec get_provider(integer()) :: {:ok, Provider.t()} | {:error, :not_found}
  def get_provider(id) do
    case AlexClaw.Repo.get(Provider, id) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  @doc "Fetch a provider by ID. Raises if not found."
  @spec get_provider!(integer()) :: Provider.t()
  def get_provider!(id), do: AlexClaw.Repo.get!(Provider, id)

  @doc "Create a new LLM provider."
  @spec create_provider(map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def create_provider(attrs) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> AlexClaw.Repo.insert()
  end

  @doc "Update an existing provider."
  @spec update_provider(Provider.t(), map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def update_provider(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> AlexClaw.Repo.update()
  end

  @doc "Delete a provider."
  @spec delete_provider(Provider.t()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def delete_provider(%Provider{} = provider) do
    AlexClaw.Repo.delete(provider)
  end

  # --- Client API ---

  @doc """
  Complete a prompt using the cheapest available model for the given tier.

  Options:
    - `:tier` — reasoning tier (:light, :medium, :heavy, :local). Default :light
    - `:system` — system prompt
    - `:provider` — explicit provider name. Bypasses tier selection.
  """
  @spec complete(String.t(), complete_opts()) :: llm_result()
  def complete(prompt, opts \\ []) do
    system = Keyword.get(opts, :system, nil)
    provider_name = Keyword.get(opts, :provider, nil)

    case resolve_provider(provider_name, opts) do
      {:ok, provider} ->
        Logger.info("LLM call: #{provider.name} (#{provider.model})", provider: provider.name)
        result = Client.call_provider(provider, prompt, system)
        if match?({:ok, _}, result), do: track_usage(provider.id)
        result

      {:error, reason} ->
        Logger.warning("No available model: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_provider(nil, opts), do: select_model(Keyword.get(opts, :tier, :light))
  defp resolve_provider("auto", opts), do: resolve_provider(nil, opts)
  defp resolve_provider("", opts), do: resolve_provider(nil, opts)

  defp resolve_provider(name, _opts) when is_binary(name) do
    case AlexClaw.Repo.one(from(p in Provider, where: p.name == ^name and p.enabled == true)) do
      nil -> {:error, {:unknown_provider, name}}
      provider -> {:ok, provider}
    end
  end

  @doc "List all provider names for UI dropdowns (includes disabled providers)."
  @spec list_provider_choices() :: [map()]
  def list_provider_choices do
    providers =
      list_providers()
      |> Enum.map(fn p ->
        suffix = if p.enabled, do: "", else: " [disabled]"
        %{value: p.name, label: "#{p.name} (#{p.model})#{suffix}", group: p.tier}
      end)

    [%{value: "auto", label: "Auto (tier-based)", group: "auto"} | providers]
  end

  @doc """
  Generate a 768-dimension embedding for the given text.

  Resolves an embedding provider via config (`embedding.provider`) or auto-detects
  the first available Gemini → Ollama → OpenAI-compatible provider.

  Options:
    - `:provider` — explicit provider name (bypasses config/auto-detect)
  """
  @spec embed(String.t(), keyword()) :: {:ok, list(float())} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    case resolve_embedding_provider(opts) do
      {:ok, provider} ->
        model = AlexClaw.Config.get("embedding.model") || "text-embedding-004"
        result = Client.call_embedding(provider, text, model)
        if match?({:ok, _}, result), do: track_usage(provider.id)
        result

      {:error, reason} ->
        Logger.warning("No embedding provider available: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_embedding_provider(opts) do
    case Keyword.get(opts, :provider) do
      name when is_binary(name) and name != "" ->
        resolve_provider(name, [])

      _ ->
        configured = AlexClaw.Config.get("embedding.provider")

        if configured && configured != "" do
          resolve_provider(configured, [])
        else
          auto_detect_embedding_provider()
        end
    end
  end

  defp auto_detect_embedding_provider do
    query =
      from(p in Provider,
        where: p.enabled == true,
        order_by: [asc: p.priority, asc: p.name]
      )

    providers = AlexClaw.Repo.all(query)

    result =
      Enum.find(providers, &(&1.type == "gemini")) ||
        Enum.find(providers, &(&1.type == "ollama")) ||
        Enum.find(providers, &(&1.type in ["openai_compatible", "custom"]))

    case result do
      nil -> {:error, :no_embedding_provider}
      provider -> {:ok, provider}
    end
  end

  # --- Model Selection ---

  defp select_model(tier) do
    tier_str = Atom.to_string(tier)

    providers =
      AlexClaw.Repo.all(
        from(p in Provider,
          where: p.enabled == true and p.tier == ^tier_str,
          order_by: [asc: p.priority, asc: p.name]
        )
      )

    case providers do
      [] ->
        # Fall back to local tier providers if no providers found for requested tier
        if tier != :local do
          select_model(:local)
        else
          {:error, :no_available_model}
        end

      providers ->
        case Enum.find(providers, &within_limit?/1) do
          nil -> {:error, :all_providers_at_limit}
          provider -> {:ok, provider}
        end
    end
  end

  defp within_limit?(%Provider{daily_limit: nil}), do: true
  defp within_limit?(%Provider{id: id, daily_limit: limit}), do: get_usage(id) < limit

  # --- Usage Tracking (ETS) ---

  @table :alexclaw_llm_usage

  @doc "Create the ETS table for tracking daily LLM usage counts."
  @spec init_usage_table() :: :ets.table()
  def init_usage_table do
    :ets.new(@table, [:named_table, :public, :set])
  end

  defp track_usage(provider_id) when is_integer(provider_id) do
    key = {provider_id, Date.utc_today()}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    AlexClaw.LLM.UsageTracker.persist(provider_id)
  end

  defp get_usage(provider_id) when is_integer(provider_id) do
    key = {provider_id, Date.utc_today()}

    case :ets.lookup(@table, key) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  @doc "Get today's usage count for a provider by ID."
  @spec usage_today(integer()) :: non_neg_integer()
  def usage_today(provider_id), do: get_usage(provider_id)

end
