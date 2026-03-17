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
    %{name: "Gemini Flash", type: "gemini", tier: "light", model: "gemini-2.0-flash",
      config_key: "llm.gemini_api_key", priority: 10},
    %{name: "Gemini Pro", type: "gemini", tier: "medium", model: "gemini-2.0-pro",
      config_key: "llm.gemini_api_key", priority: 10},
    %{name: "Claude Haiku", type: "anthropic", tier: "light", model: "claude-haiku-4-5-20251001",
      config_key: "llm.anthropic_api_key", priority: 20, daily_limit: 1000},
    %{name: "Claude Sonnet", type: "anthropic", tier: "medium", model: "claude-sonnet-4-6-20250514",
      config_key: "llm.anthropic_api_key", priority: 20, daily_limit: 5},
    %{name: "Claude Opus", type: "anthropic", tier: "heavy", model: "claude-opus-4-6-20250514",
      config_key: "llm.anthropic_api_key", priority: 10},
    # Local providers
    %{name: "Ollama", type: "ollama", tier: "local", model_key: "llm.ollama_model",
      host_key: "llm.ollama_host", enabled_key: "llm.ollama_enabled", priority: 50},
    %{name: "LM Studio", type: "openai_compatible", tier: "local", model_key: "llm.lmstudio_model",
      host_key: "llm.lmstudio_host", enabled_key: "llm.lmstudio_enabled", priority: 40}
  ]

  @spec seed() :: :ok
  def seed do
    existing_names =
      Repo.all(from p in Provider, select: p.name)
      |> MapSet.new()

    for default <- @defaults do
      unless MapSet.member?(existing_names, default.name) do
        attrs = build_attrs(default)

        case Repo.insert(Provider.changeset(%Provider{}, attrs)) do
          {:ok, p} -> Logger.info("Seeded LLM provider: #{p.name}")
          {:error, cs} -> Logger.warning("Failed to seed #{default.name}: #{inspect(cs.errors)}")
        end
      end
    end

    :ok
  end

  defp build_attrs(%{config_key: config_key} = default) do
    api_key = AlexClaw.Config.get(config_key) || ""

    %{
      name: default.name,
      type: default.type,
      tier: default.tier,
      model: default.model,
      api_key: api_key,
      host: Map.get(default, :host),
      daily_limit: Map.get(default, :daily_limit),
      priority: default.priority,
      enabled: api_key != ""
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
      enabled: host != ""
    }
  end
end
