defmodule AlexClaw.S4aFollowupsTest do
  @moduledoc """
  Three leaks and one mix-up found while building S4a
  (reports/S4A_SECRETS_IN_RECORDS.md, "Found along the way"):

  - a workflow export wrote a resource's full metadata, recorded fill values
    included — export redacts a resource's metadata by the same rule as MCP
    (the resource's credential shows as a placeholder; recorded values too);
  - `ApiRequest` logged the full request URL, query-string tokens included —
    it logs the host and path, never the query;
  - a 401 on a `telegram_notify` step's OWN bot token invalidated the MAIN
    Telegram token — a 401 invalidates only the token that was used.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  import ExUnit.CaptureLog

  alias AlexClaw.{Resources, Workflows}

  @secret "s4a-followup-#{System.unique_integer([:positive])}"

  describe "workflow export" do
    test "does not write a resource's recorded values or credential" do
      {:ok, wf} =
        Workflows.create_workflow(%{name: "Export #{System.unique_integer([:positive])}"})

      {:ok, res} =
        Resources.create_resource(%{
          name: "Rec #{System.unique_integer([:positive])}",
          type: "automation",
          url: "https://login.example.com",
          metadata: %{
            "steps" => [%{"action" => "fill", "selector" => "#q", "value" => @secret}]
          }
        })

      :ok = Workflows.assign_resource(wf, res)

      {:ok, exported} = Workflows.export_workflow(wf.id)
      refute Jason.encode!(exported) =~ @secret
    end
  end

  describe "api_request's log" do
    test "names the host and path, never the query string" do
      bypass = Bypass.open()
      Bypass.stub(bypass, "GET", "/data", &Plug.Conn.resp(&1, 200, "ok"))

      log =
        capture_log([level: :debug], fn ->
          AlexClaw.Skills.ApiRequest.run(%{
            config: %{"url" => "http://localhost:#{bypass.port}/data?token=#{@secret}"},
            input: nil
          })
        end)

      refute log =~ @secret, "the query string reached the log"
      assert log =~ "/data", "the log should still name the path"
    end
  end

  describe "a 401 on a step's own bot token" do
    test "does not invalidate the main Telegram token" do
      AlexClawTest.TelegramStub.accept_all("4242", reject_tokens: ["999-own-token"])

      main_before = AlexClaw.Gateway.Telegram.bot_token()

      AlexClaw.Skills.TelegramNotify.run(%{
        input: "hi",
        config: %{"bot_token" => "999-own-token", "chat_id" => "42"}
      })

      assert AlexClaw.Gateway.Telegram.bot_token() == main_before
      assert :ok = AlexClaw.Gateway.Telegram.deliver("4242", "main still works", [])
    end
  end
end
