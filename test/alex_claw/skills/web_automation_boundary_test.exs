defmodule AlexClaw.Skills.WebAutomationBoundaryTest do
  @moduledoc """
  Web automator, phase 1 (reports/WEB_AUTOMATOR_TARGET.md §1.3, §1.5).

  "Disabled" must mean off. Until now only run/1 checked
  web_automator.enabled; record/1, stop_recording/1, play/2, status/0 and
  force_stop/0 did not, so /record, /replay and /automate reached the sidecar
  with the setting false.

  And every request to the sidecar carries its token (F2). The token comes
  from the application environment (runtime.exs reads the WEB_AUTOMATOR_TOKEN_FILE file), not
  from a setting: it stays out of the database and out of exports. Without a
  token AlexClaw refuses before sending — it never talks to the sidecar
  unauthenticated.

  Each Bypass below has nothing stubbed unless a test says so: a request that
  reaches it fails the test when Bypass exits.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.WebAutomation

  @token "test-automator-token"

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

    # The chat commands (/record, /automate) no longer exist since 0.4.0 (S5b):
    # a chat refuses them always, pointing to the admin UI
    # (dispatcher/operate_not_author_test.exs) — not only while disabled.
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

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
