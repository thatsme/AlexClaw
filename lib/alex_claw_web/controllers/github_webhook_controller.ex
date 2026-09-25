defmodule AlexClawWeb.GitHubWebhookController do
  @moduledoc """
  Receives GitHub webhook events and dispatches security reviews.
  """
  use Phoenix.Controller, formats: [:json]
  require Logger

  alias AlexClaw.Config
  alias AlexClaw.Skills.GitHubSecurityReview
  alias AlexClaw.Webhooks.{GitHubEvent, GitHubSecret}
  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor

  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, params) do
    signature = List.first(get_req_header(conn, "x-hub-signature-256"))
    event = List.first(get_req_header(conn, "x-github-event"))
    raw_body = conn.assigns[:raw_body] || ""

    case verify_signature(raw_body, signature) do
      :ok ->
        dispatch_event(event, params)
        json(conn, %{status: "accepted"})

      {:error, :no_secret_configured} ->
        Logger.warning("GitHub webhook rejected: no webhook secret configured", skill: :github)
        conn |> put_status(401) |> json(%{error: "webhook secret not configured"})

      {:error, :invalid_signature} ->
        Logger.warning("GitHub webhook rejected: invalid signature", skill: :github)
        conn |> put_status(401) |> json(%{error: "invalid signature"})
    end
  end

  defp verify_signature(body, signature), do: signed(GitHubSecret.get(), body, signature)

  defp signed(secret, _body, _signature) when secret in [nil, ""],
    do: {:error, :no_secret_configured}

  defp signed(secret, body, "sha256=" <> hex_sig) do
    expected = Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

    if Plug.Crypto.secure_compare(expected, hex_sig),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp signed(_secret, _body, _signature), do: {:error, :invalid_signature}

  defp dispatch_event("pull_request", %{
         "action" => action,
         "pull_request" => pr,
         "repository" => repo
       })
       when action in ["opened", "synchronize", "reopened"] do
    repo_name = repo["full_name"]
    pr_number = pr["number"]
    Logger.info("GitHub PR ##{pr_number} #{action} on #{repo_name}", skill: :github)

    review(
      %GitHubEvent{event: :pull_request, repo: repo_name, pr_number: pr_number},
      "pull request ##{pr_number} on #{repo_name}",
      fn -> GitHubSecurityReview.review_pr(repo_name, pr_number) end
    )
  end

  defp dispatch_event("push", %{"ref" => ref, "after" => sha, "repository" => repo})
       when sha != "0000000000000000000000000000000000000000" do
    repo_name = repo["full_name"]
    branch = ref |> String.split("/") |> List.last()

    watched =
      Config.get("github.watched_branches", "main,master")
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    if branch in watched do
      Logger.info("GitHub push to #{branch} on #{repo_name}: #{String.slice(sha, 0, 8)}",
        skill: :github
      )

      review(
        %GitHubEvent{event: :push, repo: repo_name, commit_sha: sha},
        "commit #{String.slice(sha, 0, 8)} on #{repo_name}",
        fn -> GitHubSecurityReview.review_commit(repo_name, sha) end
      )
    else
      Logger.debug("GitHub push to #{branch} — not in watched branches, skipping", skill: :github)
    end
  end

  # With github.review_workflow naming an enabled workflow, the event runs it:
  # the workflow fetches the diff, reviews it and delivers the result. The event
  # is the run's input, so the first step reviews what the event named. Without
  # a workflow, the diff itself is sent, as before — no review, just the change.
  # The event is built here and only here, after the signature check: it is the
  # one place a %GitHubEvent{} comes from.
  defp review(event, what, send_diff) do
    case review_workflow() do
      nil -> send_diff.()
      workflow -> start_workflow(workflow, event, what)
    end
  end

  defp review_workflow do
    case String.trim(Config.get("github.review_workflow", "") || "") do
      "" -> nil
      name -> Enum.find(Workflows.list_workflows(), &(&1.name == name and &1.enabled))
    end
  end

  defp start_workflow(workflow, event, what) do
    Logger.info("GitHub review workflow '#{workflow.name}' for #{what}", skill: :github)

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      Executor.run_with_initial_input(workflow.id, event)
    end)

    :ok
  end

  defp dispatch_event(event, _params) do
    Logger.debug("GitHub webhook: ignoring event '#{event}'", skill: :github)
  end
end
