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
  - transit computes and checks HMACs with a key AlexClaw never holds; it
    no longer encrypts or decrypts for AlexClaw (S8 M2: nothing needs it);
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

  # What OpenBao answers AlexClaw's own token at `url`: the status alone.
  defp as_alexclaw(method, url) do
    %{req: req, token: token} = :sys.get_state(Vault)
    body = if method == :post, do: [json: %{}], else: []

    {:ok, %Req.Response{status: status}} =
      req
      |> Req.merge(
        [method: method, url: url, headers: [{"x-vault-token", token}], retry: false] ++ body
      )
      |> Req.request()

    status
  end

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

    # S8 M2: one path outside the prefix proved little. AlexClaw's own token,
    # asked through the client's own connection, at the paths an attacker
    # holding it would try.
    for {what, method, url} <- [
          {"generate a TOTP code", :get, "/v1/totp/code/admin"},
          {"read its AppRole", :get, "/v1/auth/approle/role/alexclaw"},
          {"mint a secret id", :post, "/v1/auth/approle/role/alexclaw/secret-id"},
          {"read the policies", :get, "/v1/sys/policy/alexclaw"},
          {"list the audit devices", :get, "/v1/sys/audit"},
          {"read a secret's metadata", :get, "/v1/secret/metadata/alexclaw/secrets/x"},
          {"decrypt with transit", :post, "/v1/transit/decrypt/alexclaw"},
          {"encrypt with transit", :post, "/v1/transit/encrypt/alexclaw"},
          {"look itself up (default policy)", :get, "/v1/auth/token/lookup-self"}
        ] do
      test "the token cannot #{what}" do
        assert as_alexclaw(unquote(method), unquote(url)) == 403
      end
    end

    test "the token can renew itself" do
      assert as_alexclaw(:post, "/v1/auth/token/renew-self") == 200
    end

    test "no value reaches the log" do
      p = path()

      log =
        capture_log(fn ->
          Vault.write(p, %{"password" => @value})
          Vault.read(p)
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
