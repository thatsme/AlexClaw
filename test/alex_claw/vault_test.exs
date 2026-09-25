defmodule AlexClaw.VaultTest do
  @moduledoc """
  AlexClaw's OpenBao client (reports/V040_SECURITY_DESIGN.md §4; 0.4.0 S1).

  Against the test stack's real OpenBao — static seal, TLS, initialised by
  `openbao-test-init` before the suite, exactly as production is by
  `openbao-init`. Nothing here is mocked: a property that holds against a
  fake OpenBao proves nothing about OpenBao.

  - AlexClaw logs in with its AppRole (role id and secret id from its
    bootstrap mount) and holds the token in memory only;
  - it reads and writes only under `secret/alexclaw/`; anything else is
    refused BY OPENBAO (the policy), not by AlexClaw's own code;
  - transit encrypts and decrypts with a key AlexClaw never holds;
  - OpenBao unreachable, or presenting a certificate the configured CA did
    not sign, is `{:error, reason}` — never a crash, never a retry that hides it;
  - no value ever reaches a log;
  - the client can die and come back without taking the application with it.

  The client is `AlexClaw.Vault` (the application's instance); a test that
  needs a differently configured client starts its own with
  `AlexClaw.Vault.start_link/1` and passes `server:`.
  """
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :vault

  import ExUnit.CaptureLog

  alias AlexClaw.Vault

  @value "vault-test-value-#{System.unique_integer([:positive])}"

  defp path, do: "alexclaw/test-#{System.unique_integer([:positive])}"

  describe "the application's client" do
    test "is logged in" do
      assert Vault.status() == :ok
    end

    test "writes and reads back a value under alexclaw/" do
      p = path()
      assert :ok = Vault.write(p, %{"password" => @value})
      assert {:ok, %{"password" => @value}} = Vault.read(p)
    end

    test "a path with nothing in it is not found" do
      assert {:error, :not_found} = Vault.read(path())
    end

    # The boundary is OpenBao's policy, not AlexClaw's code: the client asks,
    # OpenBao refuses.
    test "anything outside alexclaw/ is refused by OpenBao" do
      assert {:error, :forbidden} = Vault.read("other-app/secret")
      assert {:error, :forbidden} = Vault.write("other-app/secret", %{"x" => "y"})
    end

    test "transit: a round trip, and a ciphertext that does not contain the value" do
      assert {:ok, ciphertext} = Vault.encrypt(@value)
      assert String.starts_with?(ciphertext, "vault:v")
      refute ciphertext =~ @value
      assert {:ok, @value} = Vault.decrypt(ciphertext)
    end

    test "transit: a ciphertext that was not made by OpenBao is refused" do
      assert {:error, _} = Vault.decrypt("vault:v1:not-a-real-ciphertext")
    end

    test "no value reaches the log" do
      p = path()

      log =
        capture_log(fn ->
          Vault.write(p, %{"password" => @value})
          Vault.read(p)
          {:ok, c} = Vault.encrypt(@value)
          Vault.decrypt(c)
        end)

      refute log =~ @value
    end
  end

  describe "failures are values" do
    test "OpenBao unreachable" do
      config = Application.fetch_env!(:alex_claw, AlexClaw.Vault)
      name = :"vault_unreachable_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Vault, Keyword.merge(config, address: "https://127.0.0.1:1", name: name)}
      )

      assert {:error, :vault_unavailable} = Vault.read(path(), server: name)
      assert Vault.status(server: name) == {:error, :vault_unavailable}
    end

    # A server whose certificate the configured CA did not sign is not
    # OpenBao, as far as AlexClaw is concerned. The "other" CA is the image's
    # public bundle: every public CA, and not OpenBao's private one.
    test "a certificate the configured CA did not sign is refused" do
      config = Application.fetch_env!(:alex_claw, AlexClaw.Vault)
      name = :"vault_wrong_ca_#{System.unique_integer([:positive])}"

      other_ca =
        Enum.find(
          [
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/ssl/cert.pem",
            "/etc/pki/tls/certs/ca-bundle.crt"
          ],
          &File.exists?/1
        )

      assert other_ca, "no system CA bundle in the test image — the test would prove nothing"
      start_supervised!({Vault, Keyword.merge(config, ca_file: other_ca, name: name)})

      assert {:error, :vault_unavailable} = Vault.read(path(), server: name)
    end
  end

  describe "isolation" do
    test "the client can die repeatedly without stopping the application" do
      root = Process.whereis(AlexClaw.Supervisor)

      for _ <- 1..5 do
        pid = Process.whereis(Vault)
        if pid, do: Process.exit(pid, :kill)
        Process.sleep(50)
      end

      assert Process.whereis(AlexClaw.Supervisor) == root

      assert Enum.any?(1..100, fn _ -> Vault.status() == :ok or (Process.sleep(50) && false) end),
             "the client did not come back"
    end
  end
end
