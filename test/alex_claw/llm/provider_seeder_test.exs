defmodule AlexClaw.LLM.ProviderSeederTest do
  @moduledoc """
  Seeded cloud providers do not copy their setting's API key: the key has one
  home, the encrypted setting, and the client reads it from there.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.LLM.{Client, Provider, ProviderSeeder}

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
end
