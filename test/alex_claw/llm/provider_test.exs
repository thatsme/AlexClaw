defmodule AlexClaw.LLM.ProviderTest do
  use AlexClaw.DataCase, async: true

  alias AlexClaw.LLM.Provider

  describe "changeset/2" do
    test "valid with required fields" do
      cs = Provider.changeset(%Provider{}, %{
        name: "Groq",
        type: "openai_compatible",
        tier: "light",
        host: "https://api.groq.com",
        model: "llama-3-8b"
      })

      assert cs.valid?
    end

    test "valid with all fields" do
      cs = Provider.changeset(%Provider{}, %{
        name: "Custom LLM",
        type: "custom",
        tier: "heavy",
        host: "https://custom.llm.com",
        model: "custom-v1",
        api_key: "sk-test",
        daily_limit: 1000,
        headers: %{"X-Custom" => "value"},
        enabled: false
      })

      assert cs.valid?
    end

    test "invalid without name" do
      cs = Provider.changeset(%Provider{}, %{
        type: "openai_compatible", tier: "light", host: "h", model: "m"
      })
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :name)
    end

    test "type defaults to openai_compatible" do
      cs = Provider.changeset(%Provider{}, %{
        name: "X", tier: "light", host: "h", model: "m"
      })
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :type) == "openai_compatible"
    end

    test "invalid without tier" do
      cs = Provider.changeset(%Provider{}, %{
        name: "X", type: "openai_compatible", host: "h", model: "m"
      })
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :tier)
    end

    test "valid without host (cloud providers)" do
      cs = Provider.changeset(%Provider{}, %{
        name: "X", type: "gemini", tier: "light", model: "gemini-2.0-flash"
      })
      assert cs.valid?
    end

    test "invalid without model" do
      cs = Provider.changeset(%Provider{}, %{
        name: "X", type: "openai_compatible", tier: "light", host: "h"
      })
      refute cs.valid?
      assert "can't be blank" in errors_on_field(cs, :model)
    end

    test "validates tier inclusion" do
      for tier <- ~w(light medium heavy local) do
        cs = Provider.changeset(%Provider{}, %{
          name: "X", type: "openai_compatible", tier: tier, host: "h", model: "m"
        })
        assert cs.valid?, "Expected tier '#{tier}' to be valid"
      end
    end

    test "rejects invalid tier" do
      cs = Provider.changeset(%Provider{}, %{
        name: "X", type: "openai_compatible", tier: "ultra", host: "h", model: "m"
      })
      refute cs.valid?
    end

    test "validates type inclusion" do
      for type <- ~w(openai_compatible ollama gemini anthropic custom) do
        cs = Provider.changeset(%Provider{}, %{
          name: "X", type: type, tier: "light", host: "h", model: "m"
        })
        assert cs.valid?, "Expected type '#{type}' to be valid"
      end
    end

    test "rejects invalid type" do
      cs = Provider.changeset(%Provider{}, %{
        name: "X", type: "azure", tier: "light", host: "h", model: "m"
      })
      refute cs.valid?
    end

    test "defaults enabled to true" do
      cs = Provider.changeset(%Provider{}, %{
        name: "X", type: "openai_compatible", tier: "light", host: "h", model: "m"
      })
      assert Ecto.Changeset.get_field(cs, :enabled) == true
    end
  end

  defp errors_on_field(changeset, field) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Map.get(field, [])
  end
end
