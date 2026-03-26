defmodule AlexClawWeb.GitHubWebhookController do
  @moduledoc """
  Receives GitHub webhook events and dispatches security reviews.
  """
  use Phoenix.Controller, formats: [:json]
  require Logger

  alias AlexClaw.Config
  alias AlexClaw.Skills.GitHubSecurityReview

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

  defp verify_signature(_body, nil) do
    secret = Config.get("github.webhook_secret", "")
    if secret == "", do: {:error, :no_secret_configured}, else: {:error, :invalid_signature}
  end

  defp verify_signature(body, "sha256=" <> hex_sig) do
    secret = Config.get("github.webhook_secret", "")

    if secret == "" do
      {:error, :no_secret_configured}
    else
      expected = Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
      if Plug.Crypto.secure_compare(expected, hex_sig), do: :ok, else: {:error, :invalid_signature}
    end
  end

  defp verify_signature(_body, _sig), do: {:error, :invalid_signature}

  defp dispatch_event("pull_request", %{"action" => action, "pull_request" => pr, "repository" => repo})
       when action in ["opened", "synchronize", "reopened"] do
    repo_name = repo["full_name"]
    pr_number = pr["number"]
    Logger.info("GitHub PR ##{pr_number} #{action} on #{repo_name}", skill: :github)
    GitHubSecurityReview.review_pr(repo_name, pr_number)
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
      Logger.info("GitHub push to #{branch} on #{repo_name}: #{String.slice(sha, 0, 8)}", skill: :github)
      GitHubSecurityReview.review_commit(repo_name, sha)
    else
      Logger.debug("GitHub push to #{branch} — not in watched branches, skipping", skill: :github)
    end
  end

  defp dispatch_event(event, _params) do
    Logger.debug("GitHub webhook: ignoring event '#{event}'", skill: :github)
  end
end
