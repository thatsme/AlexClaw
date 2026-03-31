defmodule AlexClaw.Skills.GitHubSecurityReview do
  @moduledoc """
  GitHub diff fetcher skill.

  Fetches PR diffs, commit diffs, or latest push diffs from GitHub and
  returns formatted output. Does NOT call an LLM — add an llm_transform
  step after this one in your workflow for analysis.

  Modes (set via config "mode"):
  - "latest_pr"       — fetch diff of the most recent open PR (default)
  - "all_prs"         — fetch diffs of all open PRs
  - "latest_push"     — compare the last two commits on the default branch
  - "specific_pr"     — fetch diff of a specific PR by number
  - "specific_commit" — fetch diff of a specific commit by SHA
  """
  @behaviour AlexClaw.Skill

  @impl true
  @spec external() :: boolean()
  def external, do: true

  @impl true
  @spec description() :: String.t()
  def description, do: "Fetches PR/commit diffs from GitHub — pair with llm_transform for analysis"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_diff, :on_empty, :on_error]

  require Logger

  alias AlexClaw.Config

  @max_diff_bytes 24_000
  @github_api "https://api.github.com"

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"mode": "latest_pr", "repo": "owner/repo"}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"mode" => "latest_pr", "repo" => ""}

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "Latest PR" => %{"mode" => "latest_pr", "repo" => ""},
      "All open PRs" => %{"mode" => "all_prs", "repo" => ""},
      "Latest push" => %{"mode" => "latest_push", "repo" => ""},
      "Specific PR" => %{"mode" => "specific_pr", "repo" => "", "pr_number" => ""},
      "Specific commit" => %{"mode" => "specific_commit", "repo" => "", "commit_sha" => ""}
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help do
    "mode: latest_pr | all_prs | latest_push | specific_pr | specific_commit. " <>
      "repo: owner/repo format. pr_number: for specific_pr. commit_sha: for specific_commit."
  end

  @impl true
  @spec run(map()) :: {:ok, String.t(), atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    repo = config["repo"] || Config.get("github.default_repo", "")

    if repo == "" do
      {:error, :no_repo_configured}
    else
      token = Config.get("github.token", "")
      mode = config["mode"] || "latest_pr"

      case mode do
        "latest_pr" ->
          fetch_latest_pr(repo, token)

        "all_prs" ->
          fetch_all_prs(repo, token)

        "latest_push" ->
          fetch_latest_push(repo, token)

        "specific_pr" ->
          pr = parse_int(config["pr_number"])
          if pr, do: fetch_pr(repo, pr, token), else: {:error, :missing_pr_number}

        "specific_commit" ->
          sha = config["commit_sha"]
          if sha && sha != "", do: fetch_commit(repo, sha, token), else: {:error, :missing_commit_sha}

        _ ->
          {:error, {:unknown_mode, mode}}
      end
    end
  end

  # --- Public API for webhook controller and Telegram commands ---

  @spec review_pr(String.t(), integer() | nil, keyword()) :: :ok
  def review_pr(repo, pr_number, opts \\ []) do
    token = Config.get("github.token", "")

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      result =
        if pr_number do
          fetch_pr(repo, pr_number, token)
        else
          fetch_latest_pr(repo, token)
        end

      case result do
        {:ok, report, _branch} ->
          AlexClaw.Gateway.send_message(report, opts)

        {:error, reason} ->
          Logger.warning("PR fetch failed: #{inspect(reason)}", skill: :github)
          AlexClaw.Gateway.send_message("⚠️ Failed to fetch PR ##{pr_number}: #{inspect(reason)}", opts)
      end
    end)

    :ok
  end

  @spec review_commit(String.t(), String.t(), keyword()) :: :ok
  def review_commit(repo, sha, opts \\ []) do
    token = Config.get("github.token", "")

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      case fetch_commit(repo, sha, token) do
        {:ok, report, _branch} ->
          AlexClaw.Gateway.send_message(report, opts)

        {:error, reason} ->
          Logger.warning("Commit fetch failed: #{inspect(reason)}", skill: :github)
          AlexClaw.Gateway.send_message("⚠️ Failed to fetch commit `#{String.slice(sha, 0, 8)}`: #{inspect(reason)}", opts)
      end
    end)

    :ok
  end

  # --- Mode implementations ---

  defp fetch_latest_pr(repo, token) do
    case fetch_open_prs(repo, token, 1) do
      {:ok, [%{"number" => number} | _]} -> fetch_pr(repo, number, token)
      {:ok, []} -> {:ok, "No open PRs found for #{repo}.", :on_empty}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_all_prs(repo, token) do
    case fetch_open_prs(repo, token, 30) do
      {:ok, []} ->
        {:ok, "No open PRs found for #{repo}.", :on_empty}

      {:ok, prs} ->
        results =
          Enum.map(prs, fn %{"number" => number} ->
            case fetch_pr(repo, number, token) do
              {:ok, report, _branch} -> {:ok, number, report}
              {:error, reason} -> {:error, number, reason}
            end
          end)

        reports = Enum.filter(results, &match?({:ok, _, _}, &1))
        errors = Enum.filter(results, &match?({:error, _, _}, &1))

        combined =
          Enum.map_join(reports, "\n---\n\n", fn {:ok, _number, report} -> report end)

        error_note =
          if errors != [] do
            failed = Enum.map_join(errors, ", ", fn {:error, n, _} -> "##{n}" end)
            "\n\n⚠️ Failed to fetch: #{failed}"
          else
            ""
          end

        {:ok, combined <> error_note, :on_diff}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_latest_push(repo, token) do
    Logger.info("latest_push: fetching last 2 commits for #{repo}", skill: :github)

    case fetch_recent_commits(repo, token, 2) do
      {:ok, [latest, previous | _]} ->
        base_sha = previous["sha"]
        head_sha = latest["sha"]
        fetch_compare(repo, base_sha, head_sha, token)

      {:ok, [single | _]} ->
        fetch_commit(repo, single["sha"], token)

      {:ok, []} ->
        {:ok, "No commits found for #{repo}.", :on_empty}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Fetch and format ---

  defp fetch_pr(repo, pr_number, token) do
    Logger.info("Fetching PR ##{pr_number} on #{repo}", skill: :github)

    with {:ok, meta} <- fetch_pr_meta(repo, pr_number, token),
         {:ok, diff} <- fetch_pr_diff(repo, pr_number, token) do
      output = format_pr(repo, pr_number, meta, truncate_diff(diff))
      {:ok, output, :on_diff}
    end
  end

  defp fetch_commit(repo, sha, token) do
    Logger.info("Fetching commit #{String.slice(sha, 0, 8)} on #{repo}", skill: :github)

    with {:ok, meta} <- fetch_commit_meta(repo, sha, token),
         {:ok, diff} <- fetch_commit_diff(repo, sha, token) do
      output = format_commit(repo, sha, meta, truncate_diff(diff))
      {:ok, output, :on_diff}
    end
  end

  defp fetch_compare(repo, base_sha, head_sha, token) do
    short_base = String.slice(base_sha, 0, 8)
    short_head = String.slice(head_sha, 0, 8)
    Logger.info("Fetching compare #{short_base}...#{short_head} on #{repo}", skill: :github)

    with {:ok, compare_data} <- github_get("#{@github_api}/repos/#{repo}/compare/#{base_sha}...#{head_sha}", token),
         {:ok, diff} <- fetch_compare_diff(repo, base_sha, head_sha, token) do
      files = compare_data["files"] || []

      meta = %{
        message: "#{short_base}...#{short_head}",
        author: get_in(compare_data, ["commits", Access.at(0), "commit", "author", "name"]) || "multiple",
        url: compare_data["html_url"],
        additions: Enum.reduce(files, 0, &(&1["additions"] + &2)),
        deletions: Enum.reduce(files, 0, &(&1["deletions"] + &2)),
        changed_files: length(files)
      }

      output = format_commit(repo, "#{short_base}...#{short_head}", meta, truncate_diff(diff))
      {:ok, output, :on_diff}
    end
  end

  # --- Formatting ---

  defp format_pr(repo, pr_number, meta, diff) do
    """
    GitHub PR — #{repo} ##{pr_number}
    Title: #{meta.title}
    Author: #{meta.author} | #{meta.head} → #{meta.base}
    Changes: +#{meta.additions}/-#{meta.deletions} across #{meta.changed_files} file(s)
    URL: #{meta.url}

    ```diff
    #{diff}
    ```
    """
  end

  defp format_commit(repo, ref, meta, diff) do
    short = String.slice(to_string(ref), 0, 20)
    first_line = (meta.message || "") |> String.split("\n") |> hd() |> String.slice(0, 100)

    """
    GitHub Commit — #{repo} #{short}
    Message: #{first_line}
    Author: #{meta.author}
    Changes: +#{meta.additions}/-#{meta.deletions} across #{meta.changed_files} file(s)
    URL: #{meta[:url]}

    ```diff
    #{diff}
    ```
    """
  end

  # --- GitHub API ---

  defp fetch_open_prs(repo, token, per_page) do
    github_get("#{@github_api}/repos/#{repo}/pulls?state=open&sort=created&direction=desc&per_page=#{per_page}", token)
  end

  defp fetch_recent_commits(repo, token, per_page) do
    github_get("#{@github_api}/repos/#{repo}/commits?per_page=#{per_page}", token)
  end

  defp fetch_compare_diff(repo, base, head, token) do
    github_get_raw(
      "#{@github_api}/repos/#{repo}/compare/#{base}...#{head}",
      [{"accept", "application/vnd.github.v3.diff"}],
      token
    )
  end

  defp fetch_pr_meta(repo, pr_number, token) do
    case github_get("#{@github_api}/repos/#{repo}/pulls/#{pr_number}", token) do
      {:ok, body} ->
        {:ok, %{
          title: body["title"],
          author: get_in(body, ["user", "login"]),
          base: get_in(body, ["base", "ref"]),
          head: get_in(body, ["head", "ref"]),
          url: body["html_url"],
          additions: body["additions"],
          deletions: body["deletions"],
          changed_files: body["changed_files"]
        }}

      error ->
        error
    end
  end

  defp fetch_pr_diff(repo, pr_number, token) do
    github_get_raw(
      "#{@github_api}/repos/#{repo}/pulls/#{pr_number}",
      [{"accept", "application/vnd.github.v3.diff"}],
      token
    )
  end

  defp fetch_commit_meta(repo, sha, token) do
    case github_get("#{@github_api}/repos/#{repo}/commits/#{sha}", token) do
      {:ok, body} ->
        {:ok, %{
          message: get_in(body, ["commit", "message"]),
          author: get_in(body, ["commit", "author", "name"]),
          url: body["html_url"],
          additions: get_in(body, ["stats", "additions"]),
          deletions: get_in(body, ["stats", "deletions"]),
          changed_files: length(body["files"] || [])
        }}

      error ->
        error
    end
  end

  defp fetch_commit_diff(repo, sha, token) do
    github_get_raw(
      "#{@github_api}/repos/#{repo}/commits/#{sha}",
      [{"accept", "application/vnd.github.v3.diff"}],
      token
    )
  end

  defp github_get(url, token) do
    case Req.get(url, headers: github_headers(token), receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("GitHub API #{status} for #{url}: #{inspect(body)}", skill: :github)
        case status do
          404 -> {:error, :not_found}
          401 -> {:error, :unauthorized}
          403 -> {:error, :forbidden}
          _ -> {:error, {:github_api, status, body}}
        end

      {:error, reason} ->
        {:error, {:http, reason}}
    end
  end

  defp github_get_raw(url, extra_headers, token) do
    case Req.get(url, headers: github_headers(token) ++ extra_headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api, status, body}}
      {:error, reason} -> {:error, {:http, reason}}
    end
  end

  defp github_headers(token) do
    base = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "AlexClaw/1.0"}
    ]

    if token != "", do: [{"authorization", "Bearer #{token}"} | base], else: base
  end

  # --- Helpers ---

  defp truncate_diff(diff) when byte_size(diff) > @max_diff_bytes do
    binary_part(diff, 0, @max_diff_bytes)
    |> String.split("\n")
    |> Enum.drop(-1)
    |> Enum.join("\n")
    |> Kernel.<>("\n\n[diff truncated — #{byte_size(diff)} bytes total, showing first #{@max_diff_bytes}]")
  end

  defp truncate_diff(diff), do: diff

  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
