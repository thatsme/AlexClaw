defmodule AlexClaw.Auth.GateTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.Gate

  defp enable_totp do
    AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
  end

  describe "request/2" do
    test "refuses when TOTP is disabled" do
      AlexClaw.Config.set("telegram.chat_id", "123", type: "string", category: "telegram")

      assert :no_2fa = Gate.request(%{type: :run_workflow, workflow_id: 1}, "Run it")
    end

    # Without somewhere to send the prompt there is no second factor in practice.
    test "refuses when TOTP is enabled but no gateway can receive the prompt" do
      enable_totp()

      assert :no_2fa = Gate.request(%{type: :run_workflow, workflow_id: 1}, "Run it")
    end

    test "challenges when TOTP is enabled and a gateway is configured" do
      enable_totp()
      AlexClaw.Config.set("telegram.chat_id", "123", type: "string", category: "telegram")

      assert :challenged = Gate.request(%{type: :run_workflow, workflow_id: 1}, "Run it")
    end

    test "a blank chat id does not count as a gateway" do
      enable_totp()
      AlexClaw.Config.set("telegram.chat_id", "", type: "string", category: "telegram")

      assert :no_2fa = Gate.request(%{type: :run_workflow, workflow_id: 1}, "Run it")
    end

    test "a discord channel alone is enough" do
      enable_totp()
      AlexClaw.Config.set("discord.channel_id", "456", type: "string", category: "discord")

      assert :challenged = Gate.request(%{type: :run_workflow, workflow_id: 1}, "Run it")
    end
  end
end
