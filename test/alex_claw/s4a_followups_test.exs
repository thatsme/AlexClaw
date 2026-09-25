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

  import Ecto.Query
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

      {:ok, _} = Workflows.assign_resource(wf, res.id)
      {:ok, wf} = Workflows.get_workflow(wf.id)

      exported = Workflows.export_workflow(wf)

      assert Jason.encode!(exported) =~ "login.example.com",
             "the export does not include the resource — the check would prove nothing"

      refute Jason.encode!(exported) =~ @secret
    end
  end

  # Import used to create resources around Resources.create_resource, so a
  # credential in an imported file was stored in plain text (found in S4a
  # round 2). It goes through the one write path now.
  describe "workflow import" do
    test "stores an imported resource credential as a reference, never as a value" do
      name = "Imported #{System.unique_integer([:positive])}"

      data = %{
        "version" => 1,
        "workflow" => %{"name" => name},
        "steps" => [],
        "resources" => [
          %{
            "name" => "api-#{System.unique_integer([:positive])}",
            "type" => "api",
            "url" => "https://api.imported.example",
            "metadata" => %{
              "auth" => %{"header" => "Authorization", "value" => "Bearer " <> @secret}
            }
          }
        ]
      }

      assert {:ok, _} = Workflows.import_workflow(data)

      %{rows: rows} = Repo.query!("SELECT metadata::text FROM resources")

      refute Enum.any?(rows, fn [meta] -> meta =~ @secret end),
             "the credential was stored as a value"

      assert Enum.any?(rows, fn [meta] -> meta =~ ~s("secret") end), "no reference was stored"
    end
  end

  describe "api_request's log" do
    # The test environment logs only :warning and above; ApiRequest logs its
    # request at :info. Lower the level for that module alone, for this test,
    # so the line is actually there to be checked.
    setup do
      Logger.put_module_level(AlexClaw.Skills.ApiRequest, :debug)
      on_exit(fn -> Logger.delete_module_level(AlexClaw.Skills.ApiRequest) end)
    end

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

      assert log =~ "/data", "the request line is not in the log — the check would prove nothing"
      refute log =~ @secret, "the query string reached the log"
    end
  end

  describe "a 401 on a step's own bot token" do
    # The main token is held after its first resolve. If a 401 on ANOTHER
    # token invalidated it, the next main send would resolve it again — so the
    # proof is the count of resolves, not the token's value (which a re-resolve
    # returns unchanged).
    test "does not invalidate the main Telegram token" do
      AlexClawTest.TelegramStub.accept_all("4242", reject_tokens: ["999-own-token"])

      resolves = fn ->
        Repo.aggregate(
          from(e in AlexClaw.Auth.AuditEntry,
            where: e.decision == "allow" and like(e.reason, "%setting_telegram_bot_token%")
          ),
          :count
        )
      end

      :ok = AlexClaw.Gateway.Telegram.deliver("4242", "first, resolves the main token", [])
      after_first = resolves.()
      assert after_first >= 1, "the main token was never resolved — the check would prove nothing"

      AlexClaw.Skills.TelegramNotify.run(%{
        input: "hi",
        config: %{"bot_token" => "999-own-token", "chat_id" => "42"}
      })

      :ok = AlexClaw.Gateway.Telegram.deliver("4242", "main still works", [])

      assert resolves.() == after_first,
             "the main token was resolved again: the 401 on the step's own token invalidated it"
    end
  end
end
