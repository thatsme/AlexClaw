defmodule AlexClaw.LLM do
  @moduledoc """
  Multi-model LLM router. All providers live in the database.
  Routes calls to the cheapest available provider that satisfies the
  requested reasoning tier. Tracks daily usage in ETS.
  """
  import Ecto.Query

  alias AlexClaw.LLM.Provider

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
  def complete(prompt, opts \\ []), do: impl().complete(prompt, opts)

  @doc """
  Generate a 768-dimension embedding for the given text.

  Resolves an embedding provider via config (`embedding.provider`) or auto-detects
  the first available Gemini → Ollama → OpenAI-compatible provider.

  Options:
    - `:provider` — explicit provider name (bypasses config/auto-detect)
  """
  @spec embed(String.t(), keyword()) :: {:ok, list(float())} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text), do: impl().embed(text, opts)

  defp impl, do: Application.get_env(:alex_claw, :llm_impl, AlexClaw.LLM.Real)

  @doc "List all provider names for UI dropdowns (includes disabled providers)."
  @spec list_provider_choices() :: [map()]
  def list_provider_choices do
    providers =
      Enum.map(list_providers(), fn p ->
        suffix = if p.enabled, do: "", else: " [disabled]"
        %{value: p.name, label: "#{p.name} (#{p.model})#{suffix}", group: p.tier}
      end)

    [%{value: "auto", label: "Auto (tier-based)", group: "auto"} | providers]
  end

  # --- Usage Tracking (ETS) ---

  @table :alexclaw_llm_usage

  @doc "Create the ETS table for tracking daily LLM usage counts."
  @spec init_usage_table() :: :ets.table()
  def init_usage_table do
    :ets.new(@table, [:named_table, :public, :set])
  end

  @doc false
  @spec track_usage(integer()) :: any()
  def track_usage(provider_id) when is_integer(provider_id) do
    key = {provider_id, Date.utc_today()}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
    AlexClaw.LLM.UsageTracker.persist(provider_id)
  end

  @doc "Get today's usage count for a provider by ID."
  @spec usage_today(integer()) :: non_neg_integer()
  def usage_today(provider_id) when is_integer(provider_id) do
    key = {provider_id, Date.utc_today()}

    case :ets.lookup(@table, key) do
      [{_, count}] -> count
      [] -> 0
    end
  end
end
