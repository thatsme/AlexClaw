defmodule AlexClaw.EncryptionRetiredTest do
  @moduledoc """
  Since 0.4.0 (S7) no credential is stored encrypted under `SECRET_KEY_BASE`:
  every one is in OpenBao, and a record holds a reference to it
  (V040_SECURITY_DESIGN.md §6; reports/S7_PREMISES.md).

  What 0.3.x left encrypted is read once, at boot, by the upgrade
  (`AlexClaw.Config.SecretUpgrade`) through a single decrypt-only module,
  `AlexClaw.Upgrade.Legacy03`, which is marked for removal. Nothing else
  decrypts; the machinery that encrypted is gone.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  alias AlexClaw.LLM.Provider
  alias AlexClaw.Workflows.WorkflowStep

  @legacy "lib/alex_claw/upgrade/legacy03.ex"
  @upgrade [
    "lib/alex_claw/config/secret_upgrade.ex",
    "lib/alex_claw/config/secret_upgrade/records.ex"
  ]

  defp sources, do: Path.wildcard("lib/**/*.ex")

  defp code_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
    |> Enum.join("\n")
  end

  defp naming(pattern), do: for(path <- sources(), code_lines(path) =~ pattern, do: path)

  describe "only the upgrade decrypts" do
    # Every way :crypto offers to run a cipher, and Plug's MessageEncryptor —
    # not the one function the retired module happened to use (S8).
    @ciphers ~r/crypto_one_time_aead|crypto_one_time|crypto_init|crypto_update|crypto_final|crypto_dyn_iv|block_(en|de)crypt|stream_(en|de)crypt|(public|private)_(en|de)crypt|MessageEncryptor/

    test "the decrypt-only module is the one place that runs a cipher" do
      assert naming(@ciphers) == [@legacy]
    end

    test "only the boot upgrade calls it" do
      assert Enum.sort(naming(~r/Upgrade\.Legacy03|\bLegacy03\./) -- [@legacy]) ==
               Enum.sort(@upgrade)
    end

    test "it decrypts and never encrypts" do
      refute File.read!(@legacy) =~ ~r/strong_rand_bytes|, true\)/
    end

    test "it is marked for removal" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(AlexClaw.Upgrade.Legacy03)
      assert moduledoc =~ ~r/remove/i
    end
  end

  describe "the encryption machinery is gone" do
    for module <- [
          AlexClaw.Encrypted,
          AlexClaw.Encrypted.Text,
          AlexClaw.Encrypted.Map,
          AlexClaw.Encrypted.StepConfig,
          AlexClaw.Config.Crypto,
          AlexClaw.Config.EncryptExisting,
          AlexClaw.Config.Undecryptable,
          AlexClaw.Config.Rekey,
          AlexClaw.Database.EncryptCredentials,
          AlexClaw.Database.KeyCheck
        ] do
      test "#{inspect(module)}" do
        refute Code.ensure_loaded?(unquote(module))
      end
    end

    test "no release command rotates the key or discards undecryptable values" do
      Code.ensure_loaded!(AlexClaw.Release)
      refute function_exported?(AlexClaw.Release, :rekey, 0)
      refute function_exported?(AlexClaw.Release, :discard_undecryptable, 0)
      refute function_exported?(AlexClaw.Release, :discard_undecryptable, 1)
    end

    test "OLD_SECRET_KEY_BASE is gone from the deployment" do
      refute File.read!("docker-compose.yml") =~ "OLD_SECRET_KEY_BASE"
    end
  end

  describe "no schema maps a column 0.3.x encrypted" do
    test "a provider's credentials are references, not its api_key or headers columns" do
      fields = Provider.__schema__(:fields)

      refute :api_key in fields
      refute :headers in fields
      assert :credentials in fields
    end

    test "a step's config is a plain map" do
      assert WorkflowStep.__schema__(:type, :config) == :map
    end
  end
end
