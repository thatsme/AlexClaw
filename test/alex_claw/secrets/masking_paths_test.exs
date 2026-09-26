defmodule AlexClaw.Secrets.MaskingPathsTest do
  @moduledoc """
  The paths the S9 fix review found unmasked (H1, M13):

  - a photo's caption sent through a gateway;
  - a message sent with `Gateway.Telegram.deliver/3` (telegram_notify's path);
  - the OpenBao client's crash report: OTP prints the message being handled,
    and a value being written is not yet known to the mask, so the message
    itself is redacted, not masked; the crash reason is masked.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Gateway.{Router, Telegram}
  alias AlexClaw.{RecordingGateway, Secrets}
  alias AlexClawTest.TelegramStub

  @value "masked-path-value-#{System.unique_integer([:positive])}"

  defp resolved_value do
    name = "mask_path_#{System.unique_integer([:positive])}"
    {:ok, _} = Secrets.define(%{name: name, kind: "api_token", binding: ["host:example.com"]})
    :ok = Secrets.put_value(name, @value)
    {:ok, @value} = Secrets.resolve(name, for: "host:example.com")
    @value
  end

  test "a photo's caption sent through a gateway is masked" do
    RecordingGateway.install()
    value = resolved_value()

    Router.send_photo("4242", <<137, 80, 78, 71>>, "caption " <> value)

    assert Enum.any?(RecordingGateway.sent(), &(&1 =~ "[secret]"))
    refute Enum.any?(RecordingGateway.sent(), &(&1 =~ value))
  end

  test "a message delivered to Telegram is masked" do
    TelegramStub.accept_all()
    value = resolved_value()

    assert :ok = Telegram.deliver("4242", "digest " <> value, [])

    assert Enum.any?(TelegramStub.sent(), &(&1 =~ "[secret]"))
    refute Enum.any?(TelegramStub.sent(), &(&1 =~ value))
  end

  describe "the OpenBao client's crash report" do
    # What OTP passes format_status/1 when it formats a crash report.
    defp crash_status(message, reason) do
      AlexClaw.Vault.format_status(%{
        state: %{config: [], req: nil, token: "s.token", retry: 1, timer: nil},
        message: message,
        reason: reason,
        log: [{:in, message}]
      })
    end

    test "never shows a value it was writing" do
      status = crash_status({:write, "alexclaw/secrets/x", %{"value" => @value}}, :boom)

      refute inspect(status) =~ @value
      assert elem(status.message, 0) == :write, "the kind of call is kept"
    end

    test "never shows a TOTP secret it was importing, or a code it was checking" do
      for message <- [
            {:totp_import, "admin", @value, "AlexClaw", "admin"},
            {:hmac, @value},
            {:verify_hmac, @value, "vault:v1:x"},
            {:totp_validate, "admin", @value}
          ] do
        refute inspect(crash_status(message, :boom)) =~ @value, inspect(elem(message, 0))
      end
    end

    test "masks a resolved value the crash reason quotes" do
      value = resolved_value()
      status = crash_status({:read, "alexclaw/secrets/x", nil}, {:badmatch, {:ok, value}})

      refute inspect(status) =~ value
    end

    test "never shows the token" do
      refute inspect(crash_status({:read, "p", nil}, :boom)) =~ "s.token"
    end
  end
end
