defmodule AlexClaw.LLM.ProviderSeeder do
  @moduledoc """
  Seeds default LLM providers into the database on first boot.
  Reads API keys and hosts from Config (which are already seeded from env vars).
  Only creates providers that don't already exist (matched by name).
  """
  require Logger

  alias AlexClaw.LLM.Provider
  alias AlexClaw.Repo

  import Ecto.Query

  @defaults [
    # Cloud providers — priority determines selection order within a tier
    %{
      name: "Gemini Flash",
      type: "gemini",
      tier: "light",
      model: "gemini-2.0-flash",
      config_key: "llm.gemini_api_key",
      priority: 10
    },
    %{
      name: "Gemini Pro",
      type: "gemini",
      tier: "medium",
      model: "gemini-2.0-pro",
      config_key: "llm.gemini_api_key",
      priority: 10
    },
    %{
      name: "Claude Haiku",
      type: "anthropic",
      tier: "light",
      model: "claude-haiku-4-5-20251001",
      config_key: "llm.anthropic_api_key",
      priority: 20,
      daily_limit: 1000
    },
    %{
      name: "Claude Sonnet",
      type: "anthropic",
      tier: "medium",
      model: "claude-sonnet-4-6-20250514",
      config_key: "llm.anthropic_api_key",
      priority: 20,
      daily_limit: 5
    },
    %{
      name: "Claude Opus",
      type: "anthropic",
      tier: "heavy",
      model: "claude-opus-4-6-20250514",
      config_key: "llm.anthropic_api_key",
      priority: 10
    },
    # Local providers
    %{
      name: "Ollama",
      type: "ollama",
      tier: "local",
      model_key: "llm.ollama_model",
      host_key: "llm.ollama_host",
      enabled_key: "llm.ollama_enabled",
      priority: 50,
      # Ollama's own default window is 4096 tokens, and it cuts a longer prompt
      # silently. Forge's prompt alone is about 8000.
      options: %{"num_ctx" => 16_384}
    },
    %{
      name: "LM Studio",
      type: "openai_compatible",
      tier: "local",
      model_key: "llm.lmstudio_model",
      host_key: "llm.lmstudio_host",
      enabled_key: "llm.lmstudio_enabled",
      priority: 40
    }
  ]

  @spec seed() :: :ok
  def seed do
    existing_names = MapSet.new(Repo.all(from(p in Provider, select: p.name)))

    for default <- @defaults, not MapSet.member?(existing_names, default.name) do
      seed_provider(default)
    end

    :ok
  end

  defp seed_provider(default) do
    %Provider{}
    |> Provider.changeset(default |> build_attrs() |> at_most_one_local())
    |> Repo.insert()
    |> seeded(default)
  end

  # Both local providers are seeded, but only the first asked for is enabled:
  # two model servers each holding a model is more than this kind of machine
  # has. The other is there to be switched to, from Admin > LLM Providers.
  defp at_most_one_local(%{tier: "local", enabled: true, name: name} = attrs) do
    case AlexClaw.LLM.enabled_local() do
      nil ->
        attrs

      other ->
        Logger.info("Seeded #{name} disabled: #{other.name} is the enabled local provider")
        %{attrs | enabled: false}
    end
  end

  defp at_most_one_local(attrs), do: attrs

  defp seeded({:ok, provider}, _default), do: Logger.info("Seeded LLM provider: #{provider.name}")

  defp seeded({:error, changeset}, default),
    do: Logger.warning("Failed to seed #{default.name}: #{inspect(changeset.errors)}")

  # The key stays in its setting and is not copied: the LLM client reads the
  # setting for a provider that has no key of its own.
  defp build_attrs(%{config_key: config_key} = default) do
    %{
      name: default.name,
      type: default.type,
      tier: default.tier,
      model: default.model,
      host: Map.get(default, :host),
      daily_limit: Map.get(default, :daily_limit),
      priority: default.priority,
      enabled: AlexClaw.Config.secret_set_at(config_key) != nil
    }
  end

  defp build_attrs(%{enabled_key: _} = default) do
    host = AlexClaw.Config.get(default.host_key) || ""
    model = AlexClaw.Config.get(default.model_key) || ""

    %{
      name: default.name,
      type: default.type,
      tier: default.tier,
      model: if(model == "", do: "default", else: model),
      host: if(host == "", do: nil, else: host),
      daily_limit: Map.get(default, :daily_limit),
      priority: default.priority,
      options: Map.get(default, :options, %{}),
      # Enabled only when asked for: LMSTUDIO_HOST has a default, so a host
      # alone said nothing, and an unasked-for provider took the local tier.
      enabled: AlexClaw.Config.enabled?(default.enabled_key) and host != ""
    }
  end
end
