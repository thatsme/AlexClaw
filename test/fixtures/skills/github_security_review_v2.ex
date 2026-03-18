defmodule AlexClaw.Skills.Dynamic.GithubSecurityReviewV2 do
  @moduledoc """
  Dynamic GitHub security review skill.
  Fetches PR/commit diffs from GitHub, runs LLM security analysis,
  stores findings in Memory, and delivers Telegram notifications.

  Config keys: repo, token, pr_number, commit_sha, focus
  """
  @behaviour AlexClaw.Skill

  alias AlexClaw.Skills.SkillAPI

  @max_diff_bytes 24_000
  @github_api "https://api.github.com"

  @impl true
  def version, do: "1.0.0"

  @impl true
  def permissions, do: [:llm, :web_read, :telegram_send, :memory_write, :config_read]

  @impl true
  def description, do: "GitHub PR/commit security review via LLM (dynamic)"

  @impl true
  def run(args) do
    config = args[:config] || %{}

    repo =
      case config["repo"] do
        r when r in [nil, ""] -> config_get("github.default_repo", "")
        r -> r
      end

    if repo == "" do
      {:error, :no_repo_configured}
    else
      llm_opts = build_llm_opts(args)
      token = config["token"] || config_get("github.token", "")
      focus = config["focus"] || config_get("github.security_focus", default_focus())

      cond do
        config["commit_sha"] && config["commit_sha"] != "" ->
          analyse_commit(repo, config["commit_sha"], focus, llm_opts, token)

        config["pr_number"] && config["pr_number"] != "" ->
          analyse_pr(repo, parse_int(config["pr_number"]), focus, llm_opts, token)

        true ->
          case latest_open_pr(repo, token) do
            {:ok, pr_number} -> analyse_pr(repo, pr_number, focus, llm_opts, token)
            {:error, :no_open_prs} -> {:ok, "No open PRs found for #{repo}."}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  # --- Core analysis ---

  defp analyse_pr(repo, pr_number, focus, llm_opts, token) do
    with {:ok, meta} <- fetch_pr_meta(repo, pr_number, token),
         {:ok, diff} <- fetch_pr_diff(repo, pr_number, token) do
      run_analysis(:pr, repo, pr_number, meta, diff, focus, llm_opts)
    end
  end

  defp analyse_commit(repo, sha, focus, llm_opts, token) do
    with {:ok, meta} <- fetch_commit_meta(repo, sha, token),
         {:ok, diff} <- fetch_commit_diff(repo, sha, token) do
      run_analysis(:commit, repo, sha, meta, diff, focus, llm_opts)
    end
  end

  defp run_analysis(type, repo, ref, meta, diff, focus, llm_opts) do
    truncated_diff = truncate_diff(diff)

    {:ok, system} = SkillAPI.system_prompt(__MODULE__, %{skill: :research})
    prompt = build_prompt(type, repo, ref, meta, truncated_diff, focus)

    case SkillAPI.llm_complete(__MODULE__, prompt, llm_opts ++ [tier: :medium, system: system]) do
      {:ok, analysis} ->
        report = format_report(type, repo, ref, meta, analysis)

        SkillAPI.memory_store(__MODULE__, :security_review, report,
          source: build_source_url(type, repo, ref),
          metadata: %{
            type: Atom.to_string(type),
            repo: repo,
            ref: to_string(ref),
            diff_bytes: byte_size(diff),
            truncated: byte_size(diff) > @max_diff_bytes
          }
        )

        {:ok, report}

      {:error, reason} ->
        {:error, {:llm_failed, reason}}
    end
  end

  # --- GitHub API ---

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

  defp latest_open_pr(repo, token) do
    url = "#{@github_api}/repos/#{repo}/pulls?state=open&sort=created&direction=desc&per_page=1"

    case github_get(url, token) do
      {:ok, [%{"number" => number} | _]} -> {:ok, number}
      {:ok, []} -> {:error, :no_open_prs}
      error -> error
    end
  end

  defp github_get(url, token) do
    case SkillAPI.http_get(__MODULE__, url, headers: github_headers(token), receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: 403}} -> {:error, :forbidden}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api, status, body}}
      {:error, :permission_denied} -> {:error, :permission_denied}
      {:error, reason} -> {:error, {:http, reason}}
    end
  end

  defp github_get_raw(url, extra_headers, token) do
    case SkillAPI.http_get(__MODULE__, url, headers: github_headers(token) ++ extra_headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api, status, body}}
      {:error, :permission_denied} -> {:error, :permission_denied}
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

  # --- Prompts ---

  defp build_prompt(:pr, repo, pr_number, meta, diff, focus) do
    """
    You are a security-focused code reviewer. Analyse this GitHub pull request diff for security issues.

    Repository: #{repo}
    PR ##{pr_number}: #{meta.title}
    Author: #{meta.author} | Merging: #{meta.head} → #{meta.base}
    Changes: +#{meta.additions}/-#{meta.deletions} across #{meta.changed_files} file(s)

    Security focus areas: #{focus}

    Diff:
    ```diff
    #{diff}
    ```

    Reply in this exact format:

    RISK LEVEL: [CRITICAL|HIGH|MEDIUM|LOW|NONE]

    FINDINGS:
    List each finding as: [SEVERITY] Description — File:Line (if identifiable)
    If no issues found, write: No security issues identified.

    SUMMARY:
    2-3 sentences on the overall security posture of this change.

    RECOMMENDATION:
    APPROVE / REQUEST CHANGES / NEEDS FURTHER REVIEW — with one-line justification.
    """
  end

  defp build_prompt(:commit, repo, sha, meta, diff, focus) do
    """
    You are a security-focused code reviewer. Analyse this GitHub commit diff for security issues.

    Repository: #{repo}
    Commit: #{String.slice(to_string(sha), 0, 8)}
    Author: #{meta.author}
    Message: #{meta.message}
    Changes: +#{meta.additions}/-#{meta.deletions} across #{meta.changed_files} file(s)

    Security focus areas: #{focus}

    Diff:
    ```diff
    #{diff}
    ```

    Reply in this exact format:

    RISK LEVEL: [CRITICAL|HIGH|MEDIUM|LOW|NONE]

    FINDINGS:
    List each finding as: [SEVERITY] Description — File:Line (if identifiable)
    If no issues found, write: No security issues identified.

    SUMMARY:
    2-3 sentences on the overall security posture of this change.

    RECOMMENDATION:
    APPROVE / FLAG FOR REVIEW / REVERT — with one-line justification.
    """
  end

  # --- Formatting ---

  defp format_report(:pr, repo, ref, meta, analysis) do
    emoji = risk_emoji(extract_risk_level(analysis))

    """
    #{emoji} *GitHub PR Review* — #{escape_md(repo)} \##{ref}
    *#{escape_md(meta.title)}*
    Author: #{meta.author} | +#{meta.additions}/-#{meta.deletions} | #{meta.changed_files} files
    #{meta.url}

    #{analysis}
    """
  end

  defp format_report(:commit, repo, ref, meta, analysis) do
    short = String.slice(to_string(ref), 0, 8)
    emoji = risk_emoji(extract_risk_level(analysis))
    first_line = meta.message |> String.split("\n") |> hd() |> String.slice(0, 100)

    """
    #{emoji} *GitHub Commit Review* — #{escape_md(repo)} `#{short}`
    #{escape_md(first_line)}
    Author: #{meta.author} | +#{meta.additions}/-#{meta.deletions}
    #{meta.url}

    #{analysis}
    """
  end

  defp extract_risk_level(text) do
    case Regex.run(~r/RISK LEVEL:\s*(CRITICAL|HIGH|MEDIUM|LOW|NONE)/i, text) do
      [_, level] -> String.upcase(level)
      _ -> "UNKNOWN"
    end
  end

  defp risk_emoji("CRITICAL"), do: "🚨"
  defp risk_emoji("HIGH"), do: "🔴"
  defp risk_emoji("MEDIUM"), do: "🟡"
  defp risk_emoji("LOW"), do: "🟢"
  defp risk_emoji("NONE"), do: "✅"
  defp risk_emoji(_), do: "🔍"

  defp build_source_url(:pr, repo, ref), do: "https://github.com/#{repo}/pull/#{ref}"
  defp build_source_url(:commit, repo, ref), do: "https://github.com/#{repo}/commit/#{ref}"

  defp truncate_diff(diff) when byte_size(diff) > @max_diff_bytes do
    binary_part(diff, 0, @max_diff_bytes)
    |> String.split("\n")
    |> Enum.drop(-1)
    |> Enum.join("\n")
    |> Kernel.<>("\n\n[diff truncated — #{byte_size(diff)} bytes total, showing first #{@max_diff_bytes}]")
  end

  defp truncate_diff(diff), do: diff

  defp default_focus do
    "injection vulnerabilities, authentication bypass, secrets/credentials in code, " <>
      "insecure dependencies, path traversal, XSS, CSRF, SQL injection, " <>
      "hardcoded credentials, unsafe deserialization, missing input validation, privilege escalation"
  end

  defp build_llm_opts(args) do
    case args[:llm_provider] do
      p when p in [nil, "", "auto"] -> []
      provider -> [provider: provider]
    end
  end

  defp escape_md(nil), do: ""
  defp escape_md(text), do: String.replace(text, ~r/[*_`\[\]]/, "")

  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end
  defp parse_int(_), do: nil

  # --- Config helper ---

  defp config_get(key, default) do
    case SkillAPI.config_get(__MODULE__, key, default) do
      {:ok, value} -> value || default
      _ -> default
    end
  end
end
