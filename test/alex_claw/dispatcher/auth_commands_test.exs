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

  # Since 0.4.0 the second factor is managed only in the admin UI: turning it
  # off or on over a chat is refused, whatever the code — a chat is not a
  # place for the factor that guards everything else (THREAT_MODEL.md P3, P4).
  # The command answers where to do it, and changes nothing.
  describe "/disable 2fa over a gateway is refused" do
    setup do
      secret = NimbleTOTP.secret()

      AlexClaw.Config.set("auth.totp.secret", Base.encode32(secret, padding: false),
        type: "string",
        category: "auth"
      )

      AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
      AlexClaw.RecordingGateway.install()

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

    test "even with the current code, 2FA stays enabled, and the reply points to the admin UI",
         %{secret: secret} do
      Dispatcher.dispatch(msg("/disable 2fa " <> NimbleTOTP.verification_code(secret)))

      assert TOTP.enabled?()
      assert Enum.any?(AlexClaw.RecordingGateway.sent(), &(&1 =~ ~r/admin UI/i))
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
