defmodule AlexClaw.Skills.WebAutomationBoundaryTest do
  @moduledoc """
  Web automator, phase 1 (reports/WEB_AUTOMATOR_TARGET.md §1.3, §1.5).

  "Disabled" must mean off. Until now only run/1 checked
  web_automator.enabled; record/1, stop_recording/1, play/2, status/0 and
  force_stop/0 did not, so /record, /replay and /automate reached the sidecar
  with the setting false.

  And every request to the sidecar carries its token (F2). The token comes
  from the application environment (runtime.exs reads WEB_AUTOMATOR_TOKEN), not
  from a setting: it stays out of the database and out of exports. Without a
  token AlexClaw refuses before sending — it never talks to the sidecar
  unauthenticated.

  Each Bypass below has nothing stubbed unless a test says so: a request that
  reaches it fails the test when Bypass exits.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.{Dispatcher, Message, RecordingGateway}
  alias AlexClaw.Skills.WebAutomation

  @token "test-automator-token"
  @secret "s3cr3t-value-7731"

  setup do
    bypass = Bypass.open()

    insert_setting("web_automator.host", "http://localhost:#{bypass.port}",
      type: "string",
      category: "web_automator"
    )

    Application.put_env(:alex_claw, :web_automator_token, @token)
    on_exit(fn -> Application.delete_env(:alex_claw, :web_automator_token) end)

    %{bypass: bypass}
  end

  defp enable(value) do
    insert_setting("web_automator.enabled", to_string(value),
      type: "boolean",
      category: "web_automator"
    )
  end

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

  describe "with web_automator.enabled false, nothing reaches the sidecar" do
    setup do
      enable(false)
      :ok
    end

    test "every public entry point refuses" do
      assert {:error, :web_automator_disabled} =
               WebAutomation.record(%{"url" => "https://example.com"})

      assert {:error, :web_automator_disabled} = WebAutomation.stop_recording("abc12345")

      assert {:error, :web_automator_disabled} =
               WebAutomation.play(%{"url" => "https://example.com", "steps" => []}, [])

      assert {:error, :web_automator_disabled} = WebAutomation.status()
      assert {:error, :web_automator_disabled} = WebAutomation.force_stop()

      assert {:error, :web_automator_disabled} =
               WebAutomation.run(%{
                 config: %{"url" => "https://example.com", "steps" => []},
                 resources: []
               })
    end

    test "the Telegram commands refuse too, and say so" do
      RecordingGateway.install()

      for text <- [
            "/record https://example.com",
            "/record stop abc12345",
            "/automate https://example.com"
          ] do
        Dispatcher.dispatch(msg(text))
      end

      sent = RecordingGateway.sent()
      assert length(sent) >= 3, "each command answers: #{inspect(sent)}"

      assert Enum.all?(sent, &(&1 =~ ~r/disabled/i)),
             "not every answer says disabled: #{inspect(sent)}"
    end
  end

  describe "every request carries the token" do
    setup %{bypass: bypass} do
      enable(true)
      test_pid = self()

      Bypass.stub(bypass, "GET", "/status", fn conn ->
        send(test_pid, {:auth, "GET /status", Plug.Conn.get_req_header(conn, "authorization")})
        json(conn, %{"state" => "idle"})
      end)

      Bypass.stub(bypass, "POST", "/stop", fn conn ->
        send(test_pid, {:auth, "POST /stop", Plug.Conn.get_req_header(conn, "authorization")})
        json(conn, %{"message" => "Already idle"})
      end)

      Bypass.stub(bypass, "POST", "/play", fn conn ->
        send(test_pid, {:auth, "POST /play", Plug.Conn.get_req_header(conn, "authorization")})

        json(conn, %{
          "status" => "success",
          "downloads" => [],
          "screenshots" => [],
          "scraped_data" => []
        })
      end)

      Bypass.stub(bypass, "POST", "/record", fn conn ->
        send(test_pid, {:auth, "POST /record", Plug.Conn.get_req_header(conn, "authorization")})
        json(conn, %{"session_id" => "abc12345", "novnc_url" => "http://127.0.0.1:6080/vnc.html"})
      end)

      Bypass.stub(bypass, "POST", "/record/abc12345/stop", fn conn ->
        send(
          test_pid,
          {:auth, "POST /record/stop", Plug.Conn.get_req_header(conn, "authorization")}
        )

        json(conn, %{"actions" => [], "downloads" => [], "summary" => %{}})
      end)

      :ok
    end

    test "status, force_stop, play, record, stop_recording" do
      WebAutomation.status()
      WebAutomation.force_stop()
      WebAutomation.play(%{"url" => "https://example.com", "steps" => []}, [])
      WebAutomation.record(%{"url" => "https://example.com"})
      WebAutomation.stop_recording("abc12345")

      for call <- ["GET /status", "POST /stop", "POST /play", "POST /record", "POST /record/stop"] do
        assert_receive {:auth, ^call, headers}, 2_000
        assert headers == ["Bearer #{@token}"], "#{call} sent #{inspect(headers)}"
      end
    end
  end

  describe "without a token, AlexClaw does not talk to the sidecar" do
    setup do
      enable(true)
      Application.delete_env(:alex_claw, :web_automator_token)
      :ok
    end

    test "every entry point refuses before sending" do
      assert {:error, :web_automator_token_missing} = WebAutomation.status()
      assert {:error, :web_automator_token_missing} = WebAutomation.force_stop()

      assert {:error, :web_automator_token_missing} =
               WebAutomation.play(%{"url" => "https://example.com", "steps" => []}, [])

      assert {:error, :web_automator_token_missing} =
               WebAutomation.record(%{"url" => "https://example.com"})

      assert {:error, :web_automator_token_missing} = WebAutomation.stop_recording("abc12345")
    end
  end

  # automation_commands.ex:99–104 sent the whole recipe — values included — to
  # Telegram when saving a recording failed. A recorded value may be a
  # password. No gateway message about a recording carries a step's value,
  # whether the save succeeds or fails.
  describe "a recording's values never reach the gateway" do
    setup %{bypass: bypass} do
      enable(true)
      RecordingGateway.install()
      %{bypass: bypass}
    end

    test "when the recording is saved", %{bypass: bypass} do
      stub_stop(bypass, %{
        "base_url" => "https://portal.example.com/login",
        "captured_actions" => 3
      })

      Dispatcher.dispatch(msg("/record stop abc12345"))

      sent = RecordingGateway.sent()
      assert sent != []

      refute Enum.any?(sent, &String.contains?(&1, @secret)),
             "a recorded value was sent: #{inspect(sent)}"
    end

    # A summary whose base_url is not a string fails the resource's :string
    # cast (the only field the sidecar controls; name and type come from the
    # dispatcher). Verified by Claude Code, phase-1 result §2.1.
    test "when saving the recording fails", %{bypass: bypass} do
      stub_stop(bypass, %{"base_url" => 42, "captured_actions" => 3})
      Dispatcher.dispatch(msg("/record stop abc12345"))

      sent = RecordingGateway.sent()

      assert Enum.any?(sent, &(&1 =~ ~r/fail|could not|error/i)),
             "the failure was not reported: #{inspect(sent)}"

      refute Enum.any?(sent, &String.contains?(&1, @secret)),
             "a recorded value was sent: #{inspect(sent)}"
    end
  end

  # The Services page called /status with its own Req.get, so it would not
  # carry the token. Only the skill module builds sidecar requests.
  test "only WebAutomation reads the sidecar host" do
    allowed = [
      "lib/alex_claw/skills/web_automation.ex",
      "lib/alex_claw/config/seeder.ex"
    ]

    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          path not in allowed,
          File.read!(path) =~ "web_automator.host",
          do: path

    assert offenders == [],
           "these build sidecar requests outside WebAutomation: #{Enum.join(offenders, ", ")}"
  end

  defp stub_stop(bypass, summary) do
    Bypass.stub(bypass, "POST", "/record/abc12345/stop", fn conn ->
      json(conn, %{
        "actions" => [
          %{
            "action_type" => "fill",
            "selector" => "#user",
            "value" => "alex",
            "url" => "https://portal.example.com/login"
          },
          %{
            "action_type" => "fill",
            "selector" => "#password",
            "value" => @secret,
            "url" => "https://portal.example.com/login"
          },
          %{
            "action_type" => "click",
            "selector" => "button",
            "value" => "",
            "url" => "https://portal.example.com/login"
          }
        ],
        "downloads" => [],
        "summary" => summary
      })
    end)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
