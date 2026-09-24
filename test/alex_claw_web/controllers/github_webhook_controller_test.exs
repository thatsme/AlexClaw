defmodule AlexClawWeb.GitHubWebhookControllerTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.{Config, Workflows}

  @secret "test_secret"
  @sha "096ee22aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @diff "diff --git a/lib/x.ex b/lib/x.ex\n+ :ok\n"

  # Every test talks to a local stand-in for the GitHub API, the same way
  # github_diff_fetch_test.exs does (`:github_api_base` + Bypass). Once F7 is
  # fixed the review step really fetches the diff: without this the suite would
  # call api.github.com, and runs would keep writing after their test ended.
  # A request to any path not stubbed here fails the test when Bypass exits.
  setup do
    bypass = Bypass.open()
    Application.put_env(:alex_claw, :github_api_base, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:alex_claw, :github_api_base) end)

    test_pid = self()

    for path <- ["/repos/owner/repo/pulls/7", "/repos/owner/repo/commits/#{@sha}"] do
      Bypass.stub(bypass, "GET", path, fn conn ->
        send(test_pid, {:github_request, conn.request_path})
        github_response(conn)
      end)
    end

    %{bypass: bypass}
  end

  defp github_response(conn) do
    if Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github.v3.diff"] do
      Plug.Conn.resp(conn, 200, @diff)
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "title" => "Add x",
          "user" => %{"login" => "me"},
          "commit" => %{"message" => "Add x"}
        })
      )
    end
  end

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

  defp push_payload do
    %{
      "ref" => "refs/heads/main",
      "after" => @sha,
      "head_commit" => %{"id" => @sha},
      "repository" => %{"full_name" => "owner/repo"}
    }
  end

  defp review_workflow(name) do
    {:ok, workflow} = Workflows.create_workflow(%{name: name, enabled: true})

    {:ok, _} =
      Workflows.add_step(workflow, %{
        name: "diff",
        skill: "github_security_review",
        position: 1
      })

    Config.set("github.review_workflow", name, type: "string", category: "github")
    workflow
  end

  describe "POST /webhooks/github" do
    test "returns 401 when no webhook secret is configured", %{conn: conn} do
      Config.set("github.webhook_secret", "", type: "string", category: "github")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "push")
        |> post("/webhooks/github", %{"ref" => "refs/heads/main"})

      assert json_response(conn, 401)["error"] =~ "secret"
    end

    test "returns 401 with invalid HMAC signature", %{conn: conn} do
      Config.set("github.webhook_secret", @secret, type: "string", category: "github")

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
      # 0.3.54: the review step is saved only when GitHub is configured.
      Config.set("github.token", "test-token", type: "string", category: "github")
      :ok
    end

    test "a pull request runs the configured workflow", %{conn: conn} do
      workflow = review_workflow("GitHub review")

      conn = signed(conn, "pull_request", pull_request_payload())
      assert json_response(conn, 200)["status"] == "accepted"

      # Waits for the run to finish, not only to exist: a run still writing
      # when the test ends outlives its sandbox.
      assert %{} = finished_run(workflow.id)
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

  # F7: the 0.3.39 test only asserted that a run was started. These assert that
  # the first step actually reviews what the event named, and that the run
  # finishes because of it — not merely that some request left the node.
  describe "the review workflow receives the event" do
    setup do
      Config.set("github.webhook_secret", @secret, type: "string", category: "github")
      Config.set("github.token", "test-token", type: "string", category: "github")
      %{workflow: review_workflow("F7 review")}
    end

    test "a pull request event reaches step 1 and the run completes with its diff",
         %{conn: conn, workflow: workflow} do
      conn = signed(conn, "pull_request", pull_request_payload())
      assert json_response(conn, 200)["status"] == "accepted"

      assert_receive {:github_request, "/repos/owner/repo/pulls/7"}, 2_000

      run = finished_run(workflow.id)
      assert run.status == "completed", "run #{run.status}: #{inspect(run.error)}"
      assert inspect(run.step_results) =~ "lib/x.ex"
    end

    test "a push event reaches step 1 with its repository and commit",
         %{conn: conn, workflow: workflow} do
      conn = signed(conn, "push", push_payload())
      assert json_response(conn, 200)["status"] == "accepted"

      assert_receive {:github_request, path}, 2_000
      assert path == "/repos/owner/repo/commits/#{@sha}"

      run = finished_run(workflow.id)
      refute inspect(run.error) =~ "no_repo_configured"
      refute inspect(run.step_results) =~ "no_repo_configured"
    end

    # A push that deletes a branch has `after` all zeros and no head commit.
    # There is nothing to review; asking GitHub for commit 000… is a failed run
    # that looks like a broken integration. The push is on a watched branch
    # (main): on any other, the watched-branch filter drops it before the
    # all-zeros guard is reached, and the test proves nothing (mutation check,
    # 2026-09-23).
    test "a push that deletes a branch starts no review", %{conn: conn, workflow: workflow} do
      payload = %{
        "ref" => "refs/heads/main",
        "after" => String.duplicate("0", 40),
        "deleted" => true,
        "head_commit" => nil,
        "repository" => %{"full_name" => "owner/repo"}
      }

      conn = signed(conn, "push", payload)
      assert json_response(conn, 200)["status"] == "accepted"

      refute_receive {:github_request, _}, 500
      refute eventually(fn -> Workflows.list_runs(workflow.id) != [] end)
    end
  end

  defp finished_run(workflow_id) do
    assert eventually(
             fn ->
               match?(
                 [%{status: status} | _] when status in ["completed", "failed"],
                 Workflows.list_runs(workflow_id)
               )
             end,
             100
           ),
           "the run never finished"

    hd(Workflows.list_runs(workflow_id))
  end

  defp eventually(check, attempts \\ 20) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if check.(), do: {:halt, true}, else: {:cont, Process.sleep(50) == :ok and false}
    end)
  end
end
