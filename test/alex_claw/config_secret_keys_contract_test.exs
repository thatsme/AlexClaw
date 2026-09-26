defmodule AlexClaw.ConfigSecretKeysContractTest do
  @moduledoc """
  Every secret setting follows the Telegram token's pattern
  (reports/V040_SECURITY_DESIGN.md §5, §6; 0.4.0 S3).

  One table, one contract, run for each key. For every declared secret key:
  - it is declared secret, with the bindings the architect confirmed
    (2026-09-25);
  - a save stores the value in OpenBao and none in the settings table,
    catalogued with those bindings;
  - `Config.get/1` refuses it; `Config.secret/2` resolves it for each bound
    destination and refuses any other;
  - the environment never seeds it (checked on the seeder's own mapping).

  `Config.secret_bindings/1` returns the list of a key's bindings (Discord
  has two); `Config.secret_binding/1` stays for single-binding keys.

  Not in this table: `mcp.api_key`, which is not a retrievable secret at all
  (mcp_key_test.exs).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.{Config, Secrets}

  # key => bindings, as confirmed. Hosts derived from a configurable base use
  # its default here (the test env does not override them).
  @keys %{
    "telegram.bot_token" => nil,
    "github.token" => ["host:api.github.com"],
    "llm.anthropic_api_key" => ["host:api.anthropic.com"],
    "llm.gemini_api_key" => ["host:generativelanguage.googleapis.com"],
    "google.oauth.client_secret" => ["host:oauth2.googleapis.com"],
    "google.oauth.refresh_token" => ["host:oauth2.googleapis.com"],
    "discord.bot_token" => ["host:discord.com", "host:gateway.discord.gg"],
    "github.webhook_secret" => ["inbound:github_webhook"]
  }

  @value "contract-value-#{System.unique_integer([:positive])}"

  defp secret_name(key), do: "setting_" <> String.replace(key, ".", "_")

  test "the table covers every declared secret key except the MCP key (no vacuous table)" do
    declared = Config.SecretSettings.keys() |> MapSet.new()
    covered = @keys |> Map.keys() |> MapSet.new() |> MapSet.put("mcp.api_key")

    assert MapSet.equal?(declared, covered),
           "declared but not in the table: #{inspect(MapSet.difference(declared, covered))}; " <>
             "in the table but not declared: #{inspect(MapSet.difference(covered, declared))}"
  end

  for {key, bindings} <- @keys, bindings != nil do
    describe key do
      test "is declared secret, with its bindings" do
        assert Config.secret?(unquote(key))
        assert Enum.sort(Config.secret_bindings(unquote(key))) == Enum.sort(unquote(bindings))
      end

      test "a save goes to OpenBao; the settings table holds no value" do
        {:ok, _} = Config.set(unquote(key), @value, type: "string", category: "test")

        assert {:ok, %{"value" => @value}} =
                 AlexClaw.Vault.read("alexclaw/secrets/#{secret_name(unquote(key))}")

        %{rows: rows} = Repo.query!("SELECT row_to_json(s)::text FROM settings s")
        refute Enum.any?(rows, fn [json] -> json =~ @value end)

        assert Enum.sort(Secrets.get(secret_name(unquote(key))).binding) ==
                 Enum.sort(unquote(bindings))
      end

      test "Config.get/1 refuses it" do
        {:ok, _} = Config.set(unquote(key), @value, type: "string", category: "test")
        assert_raise ArgumentError, ~r/secret/i, fn -> Config.get(unquote(key)) end
      end

      test "it resolves for each bound destination, and for nothing else" do
        {:ok, _} = Config.set(unquote(key), @value, type: "string", category: "test")

        for destination <- unquote(bindings) do
          assert {:ok, @value} = Config.secret(unquote(key), for: destination)
        end

        assert {:error, :not_bound} = Config.secret(unquote(key), for: "host:evil.example")
      end
    end
  end

  # Bindings are derived from the declaration each time a secret is resolved,
  # never frozen at the first save: moving a configurable base moves the host
  # the secret may be sent to, with it.
  test "a binding follows its configuration: the Gemini key and :embedding_base_url" do
    {:ok, _} = Config.set("llm.gemini_api_key", @value, type: "string", category: "test")
    assert {:error, :not_bound} = Config.secret("llm.gemini_api_key", for: "host:embed.example")

    Application.put_env(:alex_claw, :embedding_base_url, "https://embed.example")
    on_exit(fn -> Application.delete_env(:alex_claw, :embedding_base_url) end)

    assert "host:embed.example" in Config.secret_bindings("llm.gemini_api_key")
    assert {:ok, @value} = Config.secret("llm.gemini_api_key", for: "host:embed.example")
  end

  # One home per value: no declared secret key may be seeded from the
  # environment. Checked on the seeder's own mapping, so a secret key that is
  # still mapped fails here even if no variable is set.
  test "the seeder maps no secret key to an environment variable" do
    mapped = AlexClaw.Config.Seeder.env_mapped_keys()
    assert mapped != [], "the seeder maps nothing — the check would be vacuous"

    offenders = Enum.filter(mapped, &Config.secret?/1)
    assert offenders == [], "secret keys still seeded from the environment: #{inspect(offenders)}"
  end
end
