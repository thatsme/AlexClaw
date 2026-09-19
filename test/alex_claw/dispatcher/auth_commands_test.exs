defmodule AlexClaw.Dispatcher.AuthCommandsTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.TOTP
  alias AlexClaw.{Dispatcher, Message}

  defp msg(text) do
    %Message{
      text: text,
      chat_id: "123",
      from: "Test",
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: :test
    }
  end

  describe "2FA commands routing" do
    test "/setup 2fa dispatches without crash" do
      result = Dispatcher.dispatch(msg("/setup 2fa"))
      assert result != :ignored
    end

    test "/confirm 2fa dispatches without crash" do
      result = Dispatcher.dispatch(msg("/confirm 2fa 123456"))
      assert result != :ignored
    end

    test "/disable 2fa dispatches without crash" do
      result = Dispatcher.dispatch(msg("/disable 2fa"))
      assert result != :ignored
    end
  end

  # Turning the second factor off is itself a sensitive action.
  describe "/disable 2fa requires a valid current code" do
    setup do
      secret = NimbleTOTP.secret()

      AlexClaw.Config.set("auth.totp.secret", Base.encode32(secret, padding: false),
        type: "string",
        category: "auth"
      )

      AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")

      %{secret: secret}
    end

    test "without a code, 2FA stays enabled" do
      Dispatcher.dispatch(msg("/disable 2fa"))

      assert TOTP.enabled?()
    end

    test "with a wrong code, 2FA stays enabled" do
      Dispatcher.dispatch(msg("/disable 2fa 000000"))

      assert TOTP.enabled?()
    end

    test "with a non-numeric code, 2FA stays enabled" do
      Dispatcher.dispatch(msg("/disable 2fa abcdef"))

      assert TOTP.enabled?()
    end

    test "with the current code, 2FA is disabled", %{secret: secret} do
      Dispatcher.dispatch(msg("/disable 2fa " <> NimbleTOTP.verification_code(secret)))

      refute TOTP.enabled?()
    end

    test "trailing whitespace around the code is tolerated", %{secret: secret} do
      Dispatcher.dispatch(msg("/disable 2fa  " <> NimbleTOTP.verification_code(secret) <> "  "))

      refute TOTP.enabled?()
    end
  end

  # require_2fa/3 no longer falls through to running the action unprotected.
  describe "gateway fails closed when TOTP is not configured" do
    test "/shell refuses instead of executing" do
      AlexClaw.Config.set("shell.enabled", "true", type: "boolean", category: "shell")

      assert :no_2fa =
               AlexClaw.Dispatcher.AuthCommands.require_2fa(
                 msg("/shell df -h"),
                 %{type: :shell_command, command: "df -h"},
                 "Execute: df -h"
               )
    end

    test "a skill load refuses instead of loading" do
      assert :no_2fa =
               AlexClaw.Dispatcher.AuthCommands.require_2fa(
                 msg("/skill load x.ex"),
                 %{type: :skill_load, file_path: "x.ex"},
                 "Load skill: x.ex"
               )
    end
  end

  describe "OAuth commands routing" do
    test "/connect shows available services" do
      result = Dispatcher.dispatch(msg("/connect"))
      assert result != :ignored
    end

    test "/connect google dispatches without crash" do
      result = Dispatcher.dispatch(msg("/connect google"))
      assert result != :ignored
    end

    test "/disconnect google dispatches without crash" do
      result = Dispatcher.dispatch(msg("/disconnect google"))
      assert result != :ignored
    end
  end

  describe "require_2fa/3" do
    # Was :proceed, which ran the sensitive action unprotected whenever TOTP
    # happened to be off. It now refuses.
    test "returns :no_2fa when 2FA is not enabled" do
      assert :no_2fa =
               Dispatcher.AuthCommands.require_2fa(msg("/test"), %{type: :test}, "Test action")
    end

    test "returns :challenged when 2FA is enabled" do
      AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
        type: "string",
        category: "auth"
      )

      AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")

      assert :challenged =
               Dispatcher.AuthCommands.require_2fa(msg("/test"), %{type: :test}, "Test action")
    end
  end
end
