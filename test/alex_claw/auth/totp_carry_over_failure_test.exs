defmodule AlexClaw.Auth.TotpCarryOverFailureTest do
  @moduledoc """
  A second factor from before 0.4.0 that could not be carried over is loud,
  and does not lock the admin out (S8 M11; THREAT_MODEL P10).

  At the first start the 0.3.x TOTP secret is imported into OpenBao. When
  that fails (OpenBao not ready), the upgrade's report says so, naming why.
  Until it succeeds, a code is answered "unavailable" — not "wrong": it is
  not counted against the code-entry locks.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  import ExUnit.CaptureLog

  alias AlexClaw.Auth.{CodeAttempts, TOTP}
  alias AlexClaw.Config
  alias AlexClaw.Config.SecretUpgrade
  alias AlexClawTest.Legacy

  setup do
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)

    for key <- ~w(auth.totp.enabled auth.totp.secret auth.totp.last_used_at
                  auth.totp.key auth.totp.pending),
        do: Config.delete(key)

    secret = NimbleTOTP.secret()

    Legacy.insert_setting("auth.totp.secret", Base.encode32(secret, padding: false),
      encrypted: true
    )

    Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    %{secret: secret}
  end

  defp down_vault do
    config = Application.fetch_env!(:alex_claw, AlexClaw.Vault)
    down = :"vault_down_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AlexClaw.Vault, Keyword.merge(config, address: "https://127.0.0.1:1", name: down)}
    )

    down
  end

  test "a failed import is reported by the upgrade" do
    {:ok, result} = SecretUpgrade.run(vault: down_vault())

    log = capture_log(fn -> SecretUpgrade.report(result) end)

    assert log =~ "second factor"
    assert log =~ "NOT"
  end

  test "until it is imported, a code is unavailable, not wrong", %{secret: secret} do
    code = NimbleTOTP.verification_code(secret)

    assert {:error, :unavailable} = TOTP.check(code)
  end
end
