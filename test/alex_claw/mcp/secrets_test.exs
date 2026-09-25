defmodule AlexClaw.MCP.SecretsTest do
  @moduledoc """
  MCP never returns a secret value (reports/SECRETS_INVENTORY.md #15–17;
  0.3.56, security).

  Whoever holds the MCP key — including an AI client connected to it — could
  read, in plaintext:
  - any sensitive setting through a single-key read (`alexclaw://config/<key>`):
    bot tokens, API keys, the webhook secret, OAuth secrets, the pending TOTP
    secret — while the list view redacted them, and the docs said
    `[REDACTED]`;
  - a workflow's step secrets, decrypted (`alexclaw://workflows/<id>`);
  - a resource's credentials: its `auth` header, the user:password in its
    URL, and the values a recording captured, passwords included
    (`alexclaw://resources/...`).

  One rule for every read: a secret value never leaves through MCP. The
  secret's presence can be shown; its value cannot.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.MCP.ResourceProvider
  alias Anubis.Server.{Frame, Response}

  @secret "s3cr3t-value-that-must-not-leak"

  defp read(uri) do
    {:reply, %Response{} = resp, _frame} = ResourceProvider.read(uri, Frame.new())
    resp.contents["text"]
  end

  defp refute_leak(text, what) do
    refute text =~ @secret, "#{what} returned the secret value through MCP:\n#{text}"
  end

  describe "settings" do
    for key <- ["test.sensitive.single", "telegram.bot_token", "mcp.api_key", "auth.totp.pending_secret"] do
      test "a single-key read of #{key} does not return its value" do
        AlexClaw.Config.set(unquote(key), @secret, type: "string", category: "test", sensitive: true)

        text = read("alexclaw://config/#{unquote(key)}")

        refute_leak(text, "config/#{unquote(key)}")
        assert Jason.decode!(text)["value"] == "[REDACTED]"
      end
    end

    # The single read and the list use one rule: a setting that is redacted
    # in one is redacted in the other.
    test "the single read and the list agree, key by key" do
      AlexClaw.Config.set("test.sensitive.agree", @secret, type: "string", category: "test", sensitive: true)

      listed =
        read("alexclaw://config/list")
        |> Jason.decode!()
        |> Enum.find(&(&1["key"] == "test.sensitive.agree"))

      single = read("alexclaw://config/test.sensitive.agree") |> Jason.decode!()

      assert listed["value"] == single["value"]
    end
  end

  describe "workflows" do
    test "a step's secret config is not returned decrypted" do
      AlexClawTest.TelegramStub.accept_all()

      {:ok, wf} =
        AlexClaw.Workflows.create_workflow(%{name: "MCP secrets #{System.unique_integer([:positive])}"})

      {:ok, _} =
        AlexClaw.Workflows.add_step(wf, %{
          name: "Notify",
          skill: "telegram_notify",
          config: %{"bot_token" => @secret, "chat_id" => "42"}
        })

      text = read("alexclaw://workflows/#{wf.id}")

      refute_leak(text, "workflows/#{wf.id}")
      step = text |> Jason.decode!() |> Map.fetch!("steps") |> hd()
      assert step["config"]["chat_id"] == "42", "a non-secret key must still be readable"
    end
  end

  describe "resources" do
    test "an api resource's auth header value is not returned" do
      {:ok, res} =
        AlexClaw.Resources.create_resource(%{
          name: "API #{System.unique_integer([:positive])}",
          type: "api",
          url: "https://api.example.com",
          metadata: %{"auth" => %{"header" => "Authorization", "value" => "Bearer " <> @secret}}
        })

      refute_leak(read("alexclaw://resources/#{res.id}"), "resources/#{res.id}")
      refute_leak(read("alexclaw://resources/list"), "resources/list")
    end

    test "a URL's user:password is not returned" do
      {:ok, res} =
        AlexClaw.Resources.create_resource(%{
          name: "Userinfo #{System.unique_integer([:positive])}",
          type: "website",
          url: "https://admin:#{@secret}@internal.example.com/"
        })

      text = read("alexclaw://resources/#{res.id}")
      refute_leak(text, "resources/#{res.id}")
      assert text =~ "internal.example.com", "the host must still be readable"
    end

    test "values a recording captured are not returned" do
      {:ok, res} =
        AlexClaw.Resources.create_resource(%{
          name: "Recording #{System.unique_integer([:positive])}",
          type: "automation",
          url: "https://login.example.com",
          metadata: %{
            "steps" => [
              %{"action" => "fill", "selector" => "#password", "value" => @secret,
                "description" => "Fill #password with " <> String.slice(@secret, 0, 50)}
            ]
          }
        })

      refute_leak(read("alexclaw://resources/#{res.id}"), "resources/#{res.id}")
    end
  end
end
