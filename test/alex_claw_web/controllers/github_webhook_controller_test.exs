defmodule AlexClawWeb.GitHubWebhookControllerTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

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
      AlexClaw.Config.set("github.webhook_secret", "test_secret", type: "string", category: "github")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=invalid")
        |> post("/webhooks/github", %{"ref" => "refs/heads/main"})

      assert json_response(conn, 401)["error"] =~ "signature"
    end
  end
end
