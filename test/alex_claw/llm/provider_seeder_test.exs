defmodule AlexClaw.LLM.ProviderSeederTest do
  @moduledoc """
  Seeded cloud providers do not copy their setting's API key: the key has one
  home, the encrypted setting, and the client reads it from there.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.LLM.{Client, Provider, ProviderSeeder, Window}

  defp seeded(name) do
    Repo.one!(from(p in Provider, where: p.name == ^name))
  end

  defp stored_key(id) do
    %{rows: [[value]]} = Repo.query!("SELECT api_key FROM llm_providers WHERE id = $1", [id])
    value
  end

  setup do
    Repo.delete_all(Provider)
    :ok
  end

  test "a provider whose setting holds a key is enabled, with no copy of it" do
    {:ok, _} = AlexClaw.Config.set("llm.gemini_api_key", "gm-setting", sensitive: true)

    ProviderSeeder.seed()
    flash = seeded("Gemini Flash")

    assert flash.enabled
    assert stored_key(flash.id) == nil
    assert Client.resolve_api_key(flash) == "gm-setting"
  end

  test "a provider whose setting is empty is seeded disabled" do
    {:ok, _} = AlexClaw.Config.set("llm.anthropic_api_key", "", sensitive: true)

    ProviderSeeder.seed()

    refute seeded("Claude Haiku").enabled
  end

  # LMSTUDIO_HOST has a default, so a host alone used to enable LM Studio on
  # every install, where it took the local tier without being asked for.
  test "LM Studio is seeded disabled unless it is enabled" do
    {:ok, _} = AlexClaw.Config.set("llm.lmstudio_enabled", "false")
    {:ok, _} = AlexClaw.Config.set("llm.lmstudio_host", "http://host.docker.internal:1234")
    ProviderSeeder.seed()
    refute seeded("LM Studio").enabled

    Repo.delete_all(Provider)
    {:ok, _} = AlexClaw.Config.set("llm.lmstudio_enabled", "true")
    ProviderSeeder.seed()
    assert seeded("LM Studio").enabled
  end

  test "Ollama is seeded with a 16k window, not Ollama's silent 4096 default" do
    {:ok, _} = AlexClaw.Config.set("llm.ollama_enabled", "true")
    {:ok, _} = AlexClaw.Config.set("llm.ollama_host", "http://localhost:11434")
    ProviderSeeder.seed()
    assert seeded("Ollama").options == %{"num_ctx" => 16_384}
    assert Window.tokens(seeded("Ollama")) == 16_384
  end
end
