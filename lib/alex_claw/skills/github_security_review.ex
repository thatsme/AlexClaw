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
  def description,
    do: "Fetches PR/commit diffs from GitHub — pair with llm_transform for analysis"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_diff, :on_empty, :on_error]

  require Logger

  alias AlexClaw.Config
  alias AlexClaw.Webhooks.GitHubEvent

  @max_diff_bytes 24_000
  # Configurable so the diff fetch can be tested against a local server.
  defp github_api, do: Application.get_env(:alex_claw, :github_api_base, "https://api.github.com")

  # Resolved at each use, for the API host it is sent to; "" when not set, so
  # public repositories are still read without one.
  defp github_token, do: Config.secret_value("github.token") || ""

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
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema do
    %{
      "mode" => %{type: :string, required: false},
      "repo" => %{type: :string, required: false},
      "pr_number" => %{type: :integer, required: false},
      "commit_sha" => %{type: :string, required: false}
    }
  end

  @impl true
  @spec available?() :: boolean()
  def available?, do: Config.secret_set?("github.token")

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "Latest PR" => %{"mode" => "latest_pr", "repo" => ""},
      "All open PRs" => %{"mode" => "all_prs", "repo" => ""},
      "Latest push" => %{"mode" => "latest_push", "repo" => ""},
      "Specific PR" => %{"mode" => "specific_pr", "repo" => ""},
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
    token = github_token()
    args |> review_mode() |> run_mode(args, token)
  end

  # A webhook event reviews what it names; otherwise the step config's mode decides.
  defp review_mode(args), do: mode_for(event?(args[:input]), step_config(args))

  defp mode_for(true, _config), do: :event
  defp mode_for(false, config), do: config["mode"] || "latest_pr"

  defp run_mode(mode, args, token) when mode in [:event, "specific_pr", "specific_commit"],
    do: args |> target() |> review(token)

  defp run_mode(mode, args, token) when mode in ["latest_pr", "all_prs", "latest_push"],
    do: args |> step_config() |> config_repo() |> latest(mode, token)

  defp run_mode(mode, _args, _token), do: {:error, {:unknown_mode, mode}}

  defp latest(repo, mode, token), do: repo |> valid_repo() |> latest_for(mode, token)

  defp latest_for({:ok, repo}, "latest_pr", token), do: fetch_latest_pr(repo, token)
  defp latest_for({:ok, repo}, "all_prs", token), do: fetch_all_prs(repo, token)
  defp latest_for({:ok, repo}, "latest_push", token), do: fetch_latest_push(repo, token)
  defp latest_for({:error, _reason} = error, _mode, _token), do: error

  defp review({:ok, %{repo: repo, pr_number: number}}, token), do: fetch_pr(repo, number, token)
  defp review({:ok, %{repo: repo, commit_sha: sha}}, token), do: fetch_commit(repo, sha, token)
  defp review({:error, _reason} = error, _token), do: error

  @doc """
  What to review: a repository and a pull request number or commit.

  From ONE source, never mixed: the run input when it is a verified webhook event
  (`%AlexClaw.Webhooks.GitHubEvent{}` — never a map shaped like one), otherwise the
  step config (whose repository falls back to `github.default_repo`). An event that names no
  pull request or commit is refused rather than completed from the config. A
  pull request number is normalised to an integer.
  """
  @spec target(map()) ::
          {:ok, %{repo: String.t(), pr_number: pos_integer()}}
          | {:ok, %{repo: String.t(), commit_sha: String.t()}}
          | {:error, :no_repo_configured | :no_target | :invalid_target}
  def target(args), do: target_from(args[:input], args)

  # Only a %GitHubEvent{} is an event: it is recognised by its type, never by its
  # shape, so a previous step's output shaped like one is ordinary input.
  defp target_from(%GitHubEvent{repo: repo, pr_number: number, commit_sha: sha}, _args),
    do: resolve(repo, number, sha)

  defp target_from(_not_an_event, args) do
    config = step_config(args)
    resolve(config_repo(config), config["pr_number"], config["commit_sha"])
  end

  # Everything below ends up in a GitHub API path sent with the instance's
  # token, so each part is checked before any request: a repository is exactly
  # owner/name, a PR number a positive integer, a commit a hex SHA of 7–40.
  defp resolve(repo, number, sha) do
    with {:ok, repo} <- valid_repo(repo) do
      pick(repo, number, sha)
    end
  end

  @repo_pattern ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @sha_pattern ~r/\A[0-9a-fA-F]{7,40}\z/
  @digits ~r/\A[0-9]+\z/

  defp valid_repo(repo) when repo in [nil, ""], do: {:error, :no_repo_configured}

  defp valid_repo(repo) when is_binary(repo) do
    with true <- Regex.match?(@repo_pattern, repo),
         false <- Enum.any?(String.split(repo, "/"), &(&1 in [".", ".."])) do
      {:ok, repo}
    else
      _ -> {:error, :invalid_target}
    end
  end

  defp valid_repo(_repo), do: {:error, :invalid_target}

  defp pick(_repo, nil, nil), do: {:error, :no_target}
  defp pick(repo, nil, sha), do: sha |> valid_sha() |> target_with(repo, :commit_sha)
  defp pick(repo, number, _sha), do: number |> valid_pr_number() |> target_with(repo, :pr_number)

  defp target_with({:ok, value}, repo, key), do: {:ok, %{:repo => repo, key => value}}
  defp target_with(:error, _repo, _key), do: {:error, :invalid_target}

  defp valid_pr_number(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp valid_pr_number(n) when is_binary(n) do
    with true <- Regex.match?(@digits, n),
         number when number > 0 <- String.to_integer(n) do
      {:ok, number}
    else
      _ -> :error
    end
  end

  defp valid_pr_number(_n), do: :error

  defp valid_sha(sha) when is_binary(sha) do
    if Regex.match?(@sha_pattern, sha), do: {:ok, sha}, else: :error
  end

  defp valid_sha(_sha), do: :error

  defp event?(%GitHubEvent{}), do: true
  defp event?(_input), do: false

  defp step_config(args), do: args[:config] || %{}
  defp config_repo(config), do: config["repo"] || Config.get("github.default_repo", "")

  # --- Public API for webhook controller and Telegram commands ---

  @spec review_pr(String.t(), integer() | nil, keyword()) :: :ok
  def review_pr(repo, pr_number, opts \\ []) do
    token = github_token()

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

          AlexClaw.Gateway.send_message(
            "⚠️ Failed to fetch PR ##{pr_number}: #{AlexClaw.FailureText.describe(reason)}",
            opts
          )
      end
    end)

    :ok
  end

  @spec review_commit(String.t(), String.t(), keyword()) :: :ok
  def review_commit(repo, sha, opts \\ []) do
    token = github_token()

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      case fetch_commit(repo, sha, token) do
        {:ok, report, _branch} ->
          AlexClaw.Gateway.send_message(report, opts)

        {:error, reason} ->
          Logger.warning("Commit fetch failed: #{inspect(reason)}", skill: :github)

          AlexClaw.Gateway.send_message(
            "⚠️ Failed to fetch commit `#{String.slice(sha, 0, 8)}`: #{AlexClaw.FailureText.describe(reason)}",
            opts
          )
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
      {:ok, []} -> {:ok, "No open PRs found for #{repo}.", :on_empty}
      {:ok, prs} -> combined_report(repo, prs, token)
      {:error, reason} -> {:error, reason}
    end
  end

  defp combined_report(repo, prs, token) do
    {reports, errors} =
      prs
      |> Enum.map(fn %{"number" => number} -> pr_result(repo, number, token) end)
      |> Enum.split_with(&match?({:ok, _, _}, &1))

    combined = Enum.map_join(reports, "\n---\n\n", fn {:ok, _number, report} -> report end)
    {:ok, combined <> error_note(errors), :on_diff}
  end

  defp pr_result(repo, number, token) do
    case fetch_pr(repo, number, token) do
      {:ok, report, _branch} -> {:ok, number, report}
      {:error, reason} -> {:error, number, reason}
    end
  end

  defp error_note([]), do: ""

  defp error_note(errors) do
    "\n\n⚠️ Failed to fetch: " <> Enum.map_join(errors, ", ", fn {:error, n, _} -> "##{n}" end)
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

    with {:ok, compare_data} <-
           github_get("#{github_api()}/repos/#{repo}/compare/#{base_sha}...#{head_sha}", token),
         {:ok, diff} <- fetch_compare_diff(repo, base_sha, head_sha, token) do
      files = compare_data["files"] || []

      meta = %{
        message: "#{short_base}...#{short_head}",
        author:
          get_in(compare_data, ["commits", Access.at(0), "commit", "author", "name"]) ||
            "multiple",
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
    github_get(
      "#{github_api()}/repos/#{repo}/pulls?state=open&sort=created&direction=desc&per_page=#{per_page}",
      token
    )
  end

  defp fetch_recent_commits(repo, token, per_page) do
    github_get("#{github_api()}/repos/#{repo}/commits?per_page=#{per_page}", token)
  end

  defp fetch_compare_diff(repo, base, head, token) do
    github_get_raw(
      "#{github_api()}/repos/#{repo}/compare/#{base}...#{head}",
      [{"accept", "application/vnd.github.v3.diff"}],
      token
    )
  end

  defp fetch_pr_meta(repo, pr_number, token) do
    case github_get("#{github_api()}/repos/#{repo}/pulls/#{pr_number}", token) do
      {:ok, body} ->
        {:ok,
         %{
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
      "#{github_api()}/repos/#{repo}/pulls/#{pr_number}",
      [{"accept", "application/vnd.github.v3.diff"}],
      token
    )
  end

  defp fetch_commit_meta(repo, sha, token) do
    case github_get("#{github_api()}/repos/#{repo}/commits/#{sha}", token) do
      {:ok, body} ->
        {:ok,
         %{
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
      "#{github_api()}/repos/#{repo}/commits/#{sha}",
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
        status_error(status, body)

      {:error, reason} ->
        {:error, {:http, reason}}
    end
  end

  defp status_error(404, _body), do: {:error, :not_found}
  defp status_error(401, _body), do: {:error, :unauthorized}
  defp status_error(403, _body), do: {:error, :forbidden}
  defp status_error(status, body), do: {:error, {:github_api, status, body}}

  # The extra headers replace the defaults of the same name: two Accept headers
  # made GitHub answer with the JSON one, and the diff never came.
  defp github_get_raw(url, extra_headers, token) do
    overridden = Enum.map(extra_headers, fn {name, _} -> String.downcase(name) end)
    base = Enum.reject(github_headers(token), fn {name, _} -> name in overridden end)

    case Req.get(url, headers: base ++ extra_headers, receive_timeout: 15_000) do
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
    |> Kernel.<>(
      "\n\n[diff truncated — #{byte_size(diff)} bytes total, showing first #{@max_diff_bytes}]"
    )
  end

  defp truncate_diff(diff), do: diff
end
