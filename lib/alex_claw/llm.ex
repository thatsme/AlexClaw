defmodule AlexClaw.LLM do
  @moduledoc """
  Multi-model LLM router. All providers live in the database.
  Routes calls to the cheapest available provider that satisfies the
  requested reasoning tier. Tracks daily usage in ETS.
  """
  import Ecto.Query

  alias AlexClaw.LLM.{Provider, ProviderSecrets}
  alias AlexClaw.LLM.UsageTracker

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

  @doc """
  Create a new LLM provider. Refuses a second enabled local provider. Its API
  key and headers go to OpenBao (`AlexClaw.LLM.ProviderSecrets`).
  """
  @spec create_provider(map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def create_provider(attrs) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> only_one_local()
    |> saved(nil, &AlexClaw.Repo.insert/1)
  end

  @doc """
  Update an existing provider. Refuses a second enabled local provider. A
  blank API key keeps the stored one (`AlexClaw.LLM.ProviderSecrets`).
  """
  @spec update_provider(Provider.t(), map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def update_provider(%Provider{} = provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> only_one_local()
    |> saved(provider.credentials, &AlexClaw.Repo.update/1)
  end

  defp saved(changeset, old_credentials, persist) do
    with {:ok, changeset, secrets} <- ProviderSecrets.plan(changeset, old_credentials),
         do: ProviderSecrets.saved(changeset, secrets, persist)
  end

  @doc """
  The enabled local provider, if there is one. At most one may be enabled:
  every local provider is a model server on this host, and two of them each
  holding a model is what a machine runs out of memory for.
  """
  @spec enabled_local(integer() | nil) :: Provider.t() | nil
  def enabled_local(except_id \\ nil) do
    Provider
    |> where([p], p.tier == "local" and p.enabled == true)
    |> without_id(except_id)
    |> order_by([p], asc: p.priority, asc: p.name)
    |> limit(1)
    |> AlexClaw.Repo.one()
  end

  defp without_id(query, nil), do: query
  defp without_id(query, id), do: where(query, [p], p.id != ^id)

  defp only_one_local(changeset) do
    enabled? = Ecto.Changeset.get_field(changeset, :enabled)
    tier = Ecto.Changeset.get_field(changeset, :tier)
    id = Ecto.Changeset.get_field(changeset, :id)

    refuse_second_local(changeset, enabled? and tier == "local" and enabled_local(id))
  end

  defp refuse_second_local(changeset, %Provider{} = other) do
    Ecto.Changeset.add_error(
      changeset,
      :enabled,
      "cannot be enabled: #{other.name} is the enabled local provider, and only one may run " <>
        "at a time — each is a model server holding its model in this machine's memory. " <>
        "Disable #{other.name} first."
    )
  end

  defp refuse_second_local(changeset, _none), do: changeset

  @doc "Delete a provider, and then the secrets it referenced."
  @spec delete_provider(Provider.t()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def delete_provider(%Provider{} = provider) do
    with {:ok, deleted} <- AlexClaw.Repo.delete(provider) do
      ProviderSecrets.delete(deleted)
      {:ok, deleted}
    end
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
  Complete a prompt built for each candidate provider's context window, so a
  long context is trimmed by its builder rather than cut by the model's server.
  `build` receives the tokens the prompt may use (`:unlimited` when the window
  is unknown) and answers `{:ok, prompt}` or `{:error, {:does_not_fit, tokens}}`.
  Fails with `{:prompt_too_large, [%{provider, window, prompt_tokens}]}` when
  the prompt does not fit the provider it was built for; it is not handed to
  another. See `AlexClaw.LLM.Window`.
  """
  @spec complete_fitted(
          (non_neg_integer() | :unlimited -> {:ok, String.t()} | {:error, term()}),
          complete_opts()
        ) :: llm_result()
  def complete_fitted(build, opts \\ []), do: impl().complete_fitted(build, opts)

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
    UsageTracker.persist(provider_id)
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
