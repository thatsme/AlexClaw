defmodule AlexClawWeb.GitHubWebhookControllerTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.{Config, Workflows}

  @secret "test_secret"

  defp signed(conn, event, payload) do
    body = Jason.encode!(payload)
    mac = :crypto.mac(:hmac, :sha256, @secret, body)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", event)
    |> put_req_header("x-hub-signature-256", "sha256=" <> Base.encode16(mac, case: :lower))
    |> post("/webhooks/github", body)
  end

  defp pull_request_payload do
    %{
      "action" => "opened",
      "pull_request" => %{"number" => 7},
      "repository" => %{"full_name" => "owner/repo"}
    }
  end

  describe "POST /webhooks/github" do
    test "returns 401 when no webhook secret is configured", %{conn: conn} do
      AlexClaw.Config.set("github.webhook_secret", "", type: "string", category: "github")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> post("/webhooks/github", %{"ref" => "refs/heads/main"})

      assert json_response(conn, 401)["error"] =~ "secret"
    end

    test "returns 401 with invalid HMAC signature", %{conn: conn} do
      AlexClaw.Config.set("github.webhook_secret", "test_secret",
        type: "string",
        category: "github"
      )

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=invalid")
        |> post("/webhooks/github", %{"ref" => "refs/heads/main"})

      assert json_response(conn, 401)["error"] =~ "signature"
    end
  end

  # The webhook used to send the diff and nothing else: no review was ever
  # produced. A workflow named in github.review_workflow now runs instead, so
  # the review and its delivery are steps a person can see and change.
  describe "the review workflow" do
    setup do
      Config.set("github.webhook_secret", @secret, type: "string", category: "github")
      :ok
    end

    test "a pull request runs the configured workflow", %{conn: conn} do
      {:ok, workflow} = Workflows.create_workflow(%{name: "GitHub review", enabled: true})

      {:ok, _} =
        Workflows.add_step(workflow, %{
          name: "diff",
          skill: "github_security_review",
          position: 1
        })

      Config.set("github.review_workflow", "GitHub review", type: "string", category: "github")

      conn = signed(conn, "pull_request", pull_request_payload())
      assert json_response(conn, 200)["status"] == "accepted"

      assert eventually(fn -> Workflows.list_runs(workflow.id) != [] end),
             "the webhook did not start the workflow"
    end

    test "with no workflow configured, nothing is run", %{conn: conn} do
      {:ok, workflow} = Workflows.create_workflow(%{name: "Unused", enabled: true})
      Config.set("github.review_workflow", "", type: "string", category: "github")

      conn = signed(conn, "pull_request", pull_request_payload())
      assert json_response(conn, 200)["status"] == "accepted"

      refute eventually(fn -> Workflows.list_runs(workflow.id) != [] end)
    end

    test "a workflow that is named but disabled is not run", %{conn: conn} do
      {:ok, workflow} = Workflows.create_workflow(%{name: "Disabled review", enabled: false})

      Config.set("github.review_workflow", "Disabled review",
        type: "string",
        category: "github"
      )

      conn = signed(conn, "pull_request", pull_request_payload())
      assert json_response(conn, 200)["status"] == "accepted"

      refute eventually(fn -> Workflows.list_runs(workflow.id) != [] end)
    end
  end

  defp eventually(check, attempts \\ 20) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if check.(), do: {:halt, true}, else: {:cont, Process.sleep(50) == :ok and false}
    end)
  end
end
