defmodule AlexClaw.Skills.WebAutomationTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Skills.WebAutomation

  setup do
    bypass = Bypass.open()
    insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
    insert_setting("web_automator.host", "http://localhost:#{bypass.port}", type: "string", category: "web_automator")
    {:ok, bypass: bypass}
  end

  describe "run/1 — play action" do
    test "plays automation config with steps", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        config = Jason.decode!(body)["config"]
        assert config["url"] == "https://example.com"
        assert length(config["steps"]) == 2

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "status" => "success",
          "output" => "Completed 2 steps",
          "downloads" => [],
          "screenshots" => [],
          "scraped_data" => []
        }))
      end)

      result = WebAutomation.run(%{
        config: %{
          "url" => "https://example.com",
          "steps" => [
            %{"action" => "fill", "selector" => "input", "value" => "test"},
            %{"action" => "click", "selector" => "button"}
          ]
        },
        resources: []
      })

      assert {:ok, msg, _branch} = result
      assert msg =~ "Automation complete"
      assert msg =~ "2 steps"
    end

    test "plays from automation resource when no steps in config", %{bypass: bypass} do
      {:ok, resource} = AlexClaw.Resources.create_resource(%{
        name: "Test Automation",
        type: "automation",
        url: "https://example.com",
        metadata: %{"steps" => [%{"action" => "click", "selector" => "button"}]}
      })

      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        config = Jason.decode!(body)["config"]
        assert config["url"] == "https://example.com"
        assert length(config["steps"]) == 1

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "status" => "success",
          "output" => "Done",
          "downloads" => [],
          "screenshots" => [],
          "scraped_data" => []
        }))
      end)

      resource = AlexClaw.Repo.preload(resource, [])

      result = WebAutomation.run(%{
        config: %{},
        resources: [resource]
      })

      assert {:ok, _msg, _branch} = result
    end

    test "appends extra_steps to resource steps", %{bypass: bypass} do
      {:ok, resource} = AlexClaw.Resources.create_resource(%{
        name: "Test Automation",
        type: "automation",
        url: "https://example.com",
        metadata: %{"steps" => [%{"action" => "click", "selector" => "button"}]}
      })

      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        config = Jason.decode!(body)["config"]
        steps = config["steps"]
        assert length(steps) == 3
        assert Enum.at(steps, 0)["action"] == "click"
        assert Enum.at(steps, 1)["action"] == "wait"
        assert Enum.at(steps, 2)["action"] == "scrape_text"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "status" => "success",
          "downloads" => [],
          "screenshots" => [],
          "scraped_data" => []
        }))
      end)

      resource = AlexClaw.Repo.preload(resource, [])

      result = WebAutomation.run(%{
        config: %{
          "extra_steps" => [
            %{"action" => "wait", "value" => "2"},
            %{"action" => "scrape_text"}
          ]
        },
        resources: [resource]
      })

      assert {:ok, _, _branch} = result
    end

    test "includes scraped text data in result message", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "status" => "success",
          "downloads" => [],
          "screenshots" => [],
          "scraped_data" => [%{"type" => "text", "data" => "Hello from the page"}]
        }))
      end)

      {:ok, msg, _branch} = WebAutomation.run(%{
        config: %{"url" => "https://example.com", "steps" => [%{"action" => "scrape_text"}]},
        resources: []
      })

      assert msg =~ "Hello from the page"
      assert msg =~ "1 data set(s) scraped"
    end

    test "includes table scraped data summary in result", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "status" => "success",
          "downloads" => [],
          "screenshots" => [],
          "scraped_data" => [%{
            "type" => "table",
            "headers" => ["Name", "Value"],
            "rows" => [["a", "1"], ["b", "2"]]
          }]
        }))
      end)

      {:ok, msg, _branch} = WebAutomation.run(%{
        config: %{"url" => "https://example.com", "steps" => [%{"action" => "scrape"}]},
        resources: []
      })

      assert msg =~ "table: 2 cols, 2 rows"
    end

    test "returns error on automation failure", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "status" => "error",
          "error" => "Could not click: button after 30s"
        }))
      end)

      result = WebAutomation.run(%{
        config: %{"url" => "https://example.com", "steps" => [%{"action" => "click", "selector" => "button"}]},
        resources: []
      })

      assert {:error, {:automation_failed, "Could not click: button after 30s"}} = result
    end

    test "returns error on HTTP failure", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        Plug.Conn.resp(conn, 500, "internal error")
      end)

      result = WebAutomation.run(%{
        config: %{"url" => "https://example.com", "steps" => []},
        resources: []
      })

      assert {:error, {:http, 500, _}} = result
    end
  end

  describe "run/1 — record action" do
    test "starts recording and returns session info", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/record", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "session_id" => "abc123",
          "novnc_url" => "http://localhost:6080/vnc.html"
        }))
      end)

      result = WebAutomation.run(%{
        config: %{"action" => "record", "url" => "https://example.com"}
      })

      assert {:ok, msg, _branch} = result
      assert msg =~ "abc123"
      assert msg =~ "Recording started"
    end
  end

  describe "record/1" do
    test "returns error when no URL provided" do
      assert {:error, :no_url} = WebAutomation.record(%{"url" => ""})
    end
  end

  describe "stop_recording/1" do
    test "stops recording and returns actions", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/record/sess123/stop", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "actions" => [%{"action_type" => "fill", "selector" => "input", "value" => "test"}],
          "downloads" => [],
          "summary" => %{"base_url" => "https://example.com", "captured_actions" => 1}
        }))
      end)

      assert {:ok, result} = WebAutomation.stop_recording("sess123")
      assert length(result["actions"]) == 1
    end
  end

  describe "status/0" do
    test "returns sidecar status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"state" => "idle"}))
      end)

      assert {:ok, %{"state" => "idle"}} = WebAutomation.status()
    end
  end

  describe "disabled sidecar" do
    test "returns error when web automator is disabled" do
      insert_setting("web_automator.enabled", "false", type: "boolean", category: "web_automator")

      result = WebAutomation.run(%{
        config: %{"url" => "https://example.com", "steps" => []},
        resources: []
      })

      assert {:error, :web_automator_disabled} = result
    end
  end
end
