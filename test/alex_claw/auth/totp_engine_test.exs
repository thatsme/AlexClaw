defmodule AlexClaw.Auth.TOTPEngineTest do
  @moduledoc """
  The admin's TOTP key lives in OpenBao's TOTP secrets engine; AlexClaw never
  stores it (V040_SECURITY_DESIGN.md §6; reports/S6_PREMISES.md §1; 0.4.0 S6).

  - Enrolment shows the secret once (the URI and QR code) and stores it
    nowhere in AlexClaw's database.
  - OpenBao validates codes. AlexClaw keeps its own replay guard on top — the
    engine's used-code cache lives in memory and is lost when OpenBao
    restarts — so the last accepted code stays refused for 90 seconds, as
    long as it could be valid. A fresh code is not held up.
  - OpenBao being unreachable is not a wrong code: it is refused without
    counting against the code-entry locks.
  - Turning 2FA off deletes the key in OpenBao.
  - An enrolment from before 0.4.0 is imported at the first start: the phone
    keeps its entry.
  - AlexClaw's OpenBao policy validates codes and never generates one.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  import Ecto.Query

  alias AlexClaw.Auth.{CodeAttempts, CodeEntry, Elevation, TOTP}
  alias AlexClaw.Config
  alias AlexClaw.Config.{SecretUpgrade, Setting}
  alias AlexClaw.Vault

  setup do
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)

    for key <- ~w(auth.totp.enabled auth.totp.secret auth.totp.pending_secret
                  auth.totp.last_used_at auth.totp.key auth.totp.pending),
        do: Config.delete(key)

    :ok
  end

  defp secret_from(uri) do
    uri
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("secret")
    |> Base.decode32!(padding: false)
  end

  defp code(secret, offset \\ 0),
    do: NimbleTOTP.verification_code(secret, time: System.os_time(:second) + offset)

  defp enrol do
    {:ok, %{uri: uri}} = TOTP.setup()
    secret = secret_from(uri)
    :ok = TOTP.confirm_setup(code(secret))
    secret
  end

  # Every settings row that could hold a TOTP secret, with a value.
  defp secret_rows do
    Repo.all(
      from(s in Setting,
        where: s.key in ["auth.totp.secret", "auth.totp.pending_secret"] and s.value != ""
      )
    )
  end

  describe "enrolment" do
    test "shows the secret once, and stores it nowhere in the database" do
      assert {:ok, %{uri: uri, qr_png: <<0x89, "PNG", _::binary>>}} = TOTP.setup()
      assert uri =~ "secret="
      assert secret_rows() == []
      assert {:ok, _metadata} = Vault.totp_key("admin")
    end

    test "a code from the enrolled key turns 2FA on, and no secret is left in the database" do
      enrol()

      assert TOTP.enabled?()
      assert TOTP.configured?()
      assert secret_rows() == []
    end

    test "a wrong code does not turn 2FA on" do
      {:ok, _enrolment} = TOTP.setup()

      assert {:error, :invalid_code} = TOTP.confirm_setup("000000")
      refute TOTP.enabled?()
    end
  end

  describe "codes" do
    test "a code is accepted once" do
      secret = enrol()
      # The current period's code confirmed the enrolment; the previous one is
      # still valid (skew 1) and has not been used.
      previous = code(secret, -30)

      assert :ok = TOTP.check(previous)
      assert {:error, :invalid_code} = TOTP.check(previous)
    end

    # The guard refuses a replay, not the next code: two gated actions in a row
    # need two codes, not a wait.
    test "a fresh code is accepted right after another one" do
      secret = enrol()

      assert :ok = TOTP.check(code(secret, -30))
      assert :ok = TOTP.check(code(secret, 30))
    end

    # OpenBao's record of used codes is lost when it restarts. The code below
    # was never shown to OpenBao, which would accept it; the guard's row says
    # it was the last one accepted ("<unix>:<keyed fingerprint>"), as it would
    # after a restart.
    test "the last accepted code stays refused after OpenBao forgets it" do
      secret = enrol()
      replayed = code(secret, 30)

      key =
        :alex_claw
        |> Application.fetch_env!(AlexClawWeb.Endpoint)
        |> Keyword.fetch!(:secret_key_base)

      fingerprint =
        Base.encode16(:crypto.mac(:hmac, :sha256, key, "totp-used:" <> replayed), case: :lower)

      Config.set("auth.totp.last_used_at", "#{System.os_time(:second)}:#{fingerprint}",
        type: "string",
        category: "auth"
      )

      assert {:error, :invalid_code} = TOTP.check(replayed)
    end

    test "an unreachable OpenBao is refused as unavailable" do
      enrol()
      config = Application.fetch_env!(:alex_claw, AlexClaw.Vault)
      name = :"totp_unreachable_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Vault, Keyword.merge(config, address: "https://127.0.0.1:1", name: name)}
      )

      assert {:error, :unavailable} = TOTP.check("123456", vault: name)
    end

    test "an unavailable second factor does not count against the code-entry locks" do
      enrol()
      sid = Elevation.new_sid()

      for _attempt <- 1..(CodeAttempts.session_limit() + 1) do
        assert {:error, :unavailable} =
                 CodeEntry.verify_with(sid, :web, fn -> {:error, :unavailable} end)
      end

      assert :ok = CodeAttempts.status(sid)
    end
  end

  describe "turning 2FA off" do
    test "deletes the key in OpenBao" do
      secret = enrol()

      assert {:ok, :totp} = TOTP.disable_by(code(secret, -30))
      :ok = TOTP.disabled()
      assert {:error, :not_found} = Vault.totp_key("admin")
      refute TOTP.enabled?()
    end
  end

  describe "an enrolment from before 0.4.0" do
    test "is imported at the first start, and the phone's codes still work" do
      secret = NimbleTOTP.secret()

      Config.set("auth.totp.secret", Base.encode32(secret, padding: false),
        type: "string",
        category: "auth"
      )

      Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")

      assert {:ok, report} = SecretUpgrade.run()
      assert report.totp == :imported
      assert secret_rows() == []

      assert :ok = TOTP.check(code(secret))
    end
  end

  describe "AlexClaw's OpenBao policy" do
    # The policy is written once, when OpenBao is initialised (openbao/init.sh).
    test "validates and enrols the admin key, and never generates a code" do
      policy = File.read!("openbao/init.sh")

      assert policy =~ ~r/path "totp\/code\/admin" \{\s*capabilities = \["update"\]\s*\}/
      assert policy =~ ~r/path "totp\/keys\/admin" \{\s*capabilities = \[[^\]]*"update"/
      refute policy =~ ~r/path "totp\/code\/[^"]*" \{\s*capabilities = \[[^\]]*"read"/
    end
  end
end
