defmodule AlexClaw.Auth.SecondFactorIntegrityTest do
  @moduledoc """
  The second factor cannot be half-removed (S8 M9, M17; THREAT_MODEL P4).

  - Cancelling an enrolment never touches a second factor that is on: with
    2FA enabled, `cancel_setup/0` is refused and the key stays in OpenBao,
    whatever pending marker the settings hold.
  - Disabling happens in the control plane's transaction, as the code is
    checked (`TOTP.disable_by/1`). Inside it only the database changes; the
    cache and OpenBao follow once it commits (`TOTP.disabled/0`). A rollback —
    the audit row could not be written — leaves 2FA on everywhere: the cache
    says so, and the key still answers.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{CodeAttempts, TOTP}
  alias AlexClaw.Config

  setup do
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)

    for key <- ~w(auth.totp.enabled auth.totp.secret auth.totp.pending_secret
                  auth.totp.last_used_at auth.totp.key auth.totp.pending),
        do: Config.delete(key)

    :ok
  end

  defp code(secret, offset \\ 0),
    do: NimbleTOTP.verification_code(secret, time: System.os_time(:second) + offset)

  defp enrol do
    {:ok, %{uri: uri}} = TOTP.setup()

    secret =
      uri
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("secret")
      |> Base.decode32!(padding: false)

    :ok = TOTP.confirm_setup(code(secret))
    secret
  end

  describe "cancelling an enrolment" do
    test "is refused while 2FA is on, and the key stays" do
      secret = enrol()
      # A pending marker beside an enabled factor: a restored file (before
      # 0.4.0's restore fix) or a setup racing a confirm.
      {:ok, _} = Config.set("auth.totp.pending", "true")

      assert {:error, :already_enabled} = TOTP.cancel_setup()
      assert TOTP.enabled?()
      assert :ok = TOTP.check(code(secret, 30))
    end
  end

  describe "a disable rolled back" do
    test "leaves 2FA on in the cache and the key in OpenBao" do
      secret = enrol()

      {:error, :audit_failed} =
        Repo.transaction(fn ->
          {:ok, :totp} = TOTP.disable_by(code(secret, -30))
          Repo.rollback(:audit_failed)
        end)

      assert TOTP.enabled?(), "the cache says 2FA is off"
      assert :ok = TOTP.check(code(secret, 30)), "the key in OpenBao is gone"
    end

    test "a disable that commits turns everything off" do
      secret = enrol()

      {:ok, {:ok, :totp}} = Repo.transaction(fn -> TOTP.disable_by(code(secret, 30)) end)
      :ok = TOTP.disabled()

      refute TOTP.enabled?()
      refute TOTP.key_recorded?()
    end
  end
end
