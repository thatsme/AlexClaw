defmodule AlexClaw.Dispatcher do
  @moduledoc """
  Routes incoming messages and scheduled events to the correct skill.
  Pattern matches on message content — no LLM for routing.

  Command groups are delegated to focused modules:
  - `SkillCommands` — /skill load|unload|reload|create|list
  - `AutomationCommands` — /record, /replay, /automate
  - `AuthCommands` — 2FA setup/confirm/disable, OAuth connect/disconnect
  """
  require Logger

  alias AlexClaw.{Config, Message, Gateway, SkillSupervisor}
  alias AlexClaw.Dispatcher.{AuthCommands, AutomationCommands, CommandParser, SkillCommands}

  @spec dispatch(Message.t()) :: :ok | :ignored | term()
  def dispatch(%Message{text: "/start" <> _} = msg) do
    Gateway.send_message("🦇 *AlexClaw* is ready.\nType /help for commands.", gateway: msg.gateway)
  end

  def dispatch(%Message{text: "/ping" <> _} = msg) do
    Gateway.send_message("pong from `#{node()}`", chat_id: msg.chat_id, gateway: msg.gateway)
  end

  def dispatch(%Message{text: "/status" <> _} = msg) do
    uptime = :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
    memory = div(:erlang.memory(:total), 1_048_576)

    Gateway.send_message("""
    *AlexClaw* status
    Uptime: #{uptime}s
    Memory: #{memory} MB
    Skills running: #{DynamicSupervisor.count_children(SkillSupervisor).active}
    """, gateway: msg.gateway)
  end

  def dispatch(%Message{text: "/task add " <> title} = msg) do
    case AlexClaw.Skills.GoogleTasks.run(%{config: %{"action" => "add"}, input: String.trim(title)}) do
      {:ok, result, _branch} -> Gateway.send_message(result, gateway: msg.gateway)
      {:error, reason} -> Gateway.send_message("Failed to add task: #{inspect(reason)}", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/tasklists" <> _} = msg) do
    case AlexClaw.Skills.GoogleTasks.run(%{config: %{"action" => "lists"}}) do
      {:ok, result, _branch} -> Gateway.send_message("*Your Task Lists*\n\n#{result}", gateway: msg.gateway)
      {:error, reason} -> Gateway.send_message("Failed to fetch task lists: #{inspect(reason)}", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/tasks" <> _} = msg) do
    case AlexClaw.Skills.GoogleTasks.run(%{config: %{"action" => "list"}}) do
      {:ok, result, _branch} -> Gateway.send_message("*Your Tasks*\n\n#{result}", gateway: msg.gateway)
      {:error, reason} -> Gateway.send_message("Failed to fetch tasks: #{inspect(reason)}", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/research " <> raw} = msg) do
    {query, flags} = CommandParser.parse(String.trim(raw))

    cond do
      Keyword.get(flags, :tier) == :query ->
        tier = Config.get("skill.research.tier") || "medium"
        provider = Config.get("skill.research.provider") || "auto"
        Gateway.send_message("Research: tier=#{tier}, provider=#{provider}", gateway: msg.gateway)

      query == "" and Keyword.has_key?(flags, :tier) ->
        new_tier = Keyword.get(flags, :tier)
        Config.set("skill.research.tier", new_tier)

        if provider = Keyword.get(flags, :provider) do
          Config.set("skill.research.provider", provider)
          Gateway.send_message("Research defaults saved: tier=#{new_tier}, provider=#{provider}", gateway: msg.gateway)
        else
          Gateway.send_message("Research default tier saved: #{new_tier}", gateway: msg.gateway)
        end

      query == "" ->
        Gateway.send_message("Usage: /research [--tier light|medium|heavy|local] [--provider name] <query>", gateway: msg.gateway)

      true ->
        tier = CommandParser.resolve_tier(flags, "skill.research.tier", "medium")
        provider = CommandParser.resolve_provider(flags, "skill.research.provider")
        Gateway.send_message("Research (tier: #{tier}, provider: #{provider})", gateway: msg.gateway)
        AlexClaw.Skills.Research.handle(query, tier: tier, provider: provider, gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/search " <> raw} = msg) do
    {query, flags} = CommandParser.parse(String.trim(raw))

    cond do
      Keyword.get(flags, :tier) == :query ->
        tier = Config.get("skill.web_search.tier") || "medium"
        provider = Config.get("skill.web_search.provider") || "auto"
        Gateway.send_message("Web Search: tier=#{tier}, provider=#{provider}", gateway: msg.gateway)

      query == "" and Keyword.has_key?(flags, :tier) ->
        new_tier = Keyword.get(flags, :tier)
        Config.set("skill.web_search.tier", new_tier)

        if provider = Keyword.get(flags, :provider) do
          Config.set("skill.web_search.provider", provider)
          Gateway.send_message("Search defaults saved: tier=#{new_tier}, provider=#{provider}", gateway: msg.gateway)
        else
          Gateway.send_message("Search default tier saved: #{new_tier}", gateway: msg.gateway)
        end

      query == "" ->
        Gateway.send_message("Usage: /search [--tier light|medium|heavy|local] [--provider name] <query>", gateway: msg.gateway)

      true ->
        tier = CommandParser.resolve_tier(flags, "skill.web_search.tier", "medium")
        provider = CommandParser.resolve_provider(flags, "skill.web_search.provider")
        Gateway.send_message("Search (tier: #{tier}, provider: #{provider})", gateway: msg.gateway)
        AlexClaw.Skills.WebSearch.handle(query, tier: tier, provider: provider, gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/web " <> raw} = msg) do
    {rest, flags} = CommandParser.parse(String.trim(raw))

    if rest == "" and Keyword.has_key?(flags, :tier) do
      new_tier = Keyword.get(flags, :tier)
      Config.set("skill.web_browse.tier", new_tier)

      if provider = Keyword.get(flags, :provider) do
        Config.set("skill.web_browse.provider", provider)
        Gateway.send_message("Browse defaults saved: tier=#{new_tier}, provider=#{provider}", gateway: msg.gateway)
      else
        Gateway.send_message("Browse default tier saved: #{new_tier}", gateway: msg.gateway)
      end
    else
      tier = CommandParser.resolve_tier(flags, "skill.web_browse.tier", "light")
      provider = CommandParser.resolve_provider(flags, "skill.web_browse.provider")

      case String.split(rest, " ", parts: 2) do
        [url, question] ->
          Gateway.send_message("Browse (tier: #{tier}, provider: #{provider})", gateway: msg.gateway)
          AlexClaw.Skills.WebBrowse.handle(url, question, tier: tier, provider: provider, gateway: msg.gateway)

        [url] ->
          Gateway.send_message("Browse (tier: #{tier}, provider: #{provider})", gateway: msg.gateway)
          AlexClaw.Skills.WebBrowse.handle(url, nil, tier: tier, provider: provider, gateway: msg.gateway)
      end
    end
  end

  def dispatch(%Message{text: "/skills" <> _} = msg) do
    text =
      Enum.map_join(AlexClaw.Workflows.SkillRegistry.list_all_with_type(), "\n", fn {name, module, type, perms, _routes, _ext} ->
        desc =
          if function_exported?(module, :description, 0),
            do: module.description(),
            else: "—"

        tag = if type == :dynamic, do: " `[dynamic]`", else: ""
        perm_text = if type == :dynamic and is_list(perms),
          do: " — permissions: #{Enum.join(perms, ", ")}",
          else: ""

        "• *#{name}*#{tag} — #{desc}#{perm_text}"
      end)

    Gateway.send_message("*AlexClaw Skills*\n\n#{text}", gateway: msg.gateway)
  end

  # --- Delegated Command Groups ---

  def dispatch(%Message{text: "/skill" <> _} = msg) do
    Gateway.send_message("Skill management is only available from the Admin UI.\n2FA verification will be sent here when actions are performed.", gateway: msg.gateway)
  end

  def dispatch(%Message{text: "/record " <> _} = msg), do: AutomationCommands.dispatch(msg)
  def dispatch(%Message{text: "/replay " <> _} = msg), do: AutomationCommands.dispatch(msg)
  def dispatch(%Message{text: "/automate " <> _} = msg), do: AutomationCommands.dispatch(msg)

  def dispatch(%Message{text: "/setup 2fa" <> _} = msg), do: AuthCommands.dispatch(msg)
  def dispatch(%Message{text: "/confirm 2fa " <> _} = msg), do: AuthCommands.dispatch(msg)
  def dispatch(%Message{text: "/disable 2fa" <> _} = msg), do: AuthCommands.dispatch(msg)
  def dispatch(%Message{text: "/connect" <> _} = msg), do: AuthCommands.dispatch(msg)
  def dispatch(%Message{text: "/disconnect" <> _} = msg), do: AuthCommands.dispatch(msg)

  # --- Workflows ---

  def dispatch(%Message{text: "/workflows" <> _} = msg) do
    workflows = AlexClaw.Workflows.list_workflows()

    if workflows == [] do
      Gateway.send_message("No workflows configured.", gateway: msg.gateway)
    else
      text =
        Enum.map_join(workflows, "\n", fn wf ->
          status = if wf.enabled, do: "enabled", else: "disabled"
          schedule = if wf.schedule && wf.schedule != "", do: " `#{wf.schedule}`", else: ""
          "• *#{wf.name}* (#{status}#{schedule}) — id: #{wf.id}"
        end)

      Gateway.send_message("*AlexClaw Workflows*\n\n#{text}\n\nRun with: `/run <id>`", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/run " <> rest} = msg) do
    input = String.trim(rest)

    workflow =
      case Integer.parse(input) do
        {id, ""} ->
          AlexClaw.Repo.preload(AlexClaw.Repo.get(AlexClaw.Workflows.Workflow, id), [:steps, :resources])

        _ ->
          Enum.find(AlexClaw.Workflows.list_workflows(), &(String.downcase(&1.name) == String.downcase(input)))
      end

    if workflow do
      if workflow.metadata["requires_2fa"] do
        case AuthCommands.require_2fa(msg, %{type: :run_workflow, workflow_id: workflow.id},
               "Run workflow: *#{workflow.name}*") do
          :challenged -> :ok
          :proceed ->
            Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn -> AlexClaw.Workflows.Executor.run(workflow.id) end)
            Gateway.send_message("Workflow '#{workflow.name}' started.", gateway: msg.gateway)
        end
      else
        Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn -> AlexClaw.Workflows.Executor.run(workflow.id) end)
        Gateway.send_message("Workflow '#{workflow.name}' started.", gateway: msg.gateway)
      end
    else
      Gateway.send_message("Workflow not found: `#{input}`\nUse /workflows to see available workflows.", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/runs" <> _} = msg) do
    active = AlexClaw.Workflows.list_active_runs()

    if active == [] do
      Gateway.send_message("No workflows currently running.", gateway: msg.gateway)
    else
      text =
        Enum.map_join(active, "\n", fn run ->
          elapsed = DateTime.diff(DateTime.utc_now(), run.started_at)
          "• *#{run.workflow_name}* (run #{run.run_id}) — #{elapsed}s"
        end)

      Gateway.send_message("*Active Runs*\n\n#{text}\n\nCancel with: `/cancel <run_id>`", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/cancel " <> rest} = msg) do
    case Integer.parse(String.trim(rest)) do
      {run_id, ""} ->
        case AlexClaw.Workflows.cancel_run(run_id) do
          :ok ->
            Gateway.send_message("Run #{run_id} cancelled.", gateway: msg.gateway)

          {:error, :not_found} ->
            Gateway.send_message("Run #{run_id} not found or already finished.", gateway: msg.gateway)
        end

      _ ->
        Gateway.send_message("Usage: `/cancel <run_id>`", gateway: msg.gateway)
    end
  end

  # --- Outcome Rating ---

  def dispatch(%Message{text: "/rate " <> rest} = msg) do
    parts = String.split(String.trim(rest), " ", parts: 3)

    case parts do
      [run_id_str] ->
        show_run_outcomes(run_id_str, msg)

      [run_id_str, raw_reaction] ->
        case normalize_reaction(raw_reaction) do
          {:ok, quality} -> rate_all_outcomes(run_id_str, quality, nil, msg)
          :error -> Gateway.send_message("Unknown rating: `#{raw_reaction}`. Use `+`/`-`, `up`/`down`, or 👍/👎.", gateway: msg.gateway)
        end

      [run_id_str, second, third] ->
        # Could be: run_id reaction feedback  OR  run_id step reaction
        case normalize_reaction(second) do
          {:ok, quality} ->
            rate_all_outcomes(run_id_str, quality, third, msg)

          :error ->
            case normalize_reaction(third) do
              {:ok, quality} -> rate_step_outcome(run_id_str, second, quality, nil, msg)
              :error -> Gateway.send_message("Unknown rating. Use `+`/`-`, `up`/`down`, or 👍/👎.", gateway: msg.gateway)
            end
        end

      _ ->
        Gateway.send_message("""
        *Rate workflow outcomes*
        `/rate <run_id>` — show steps for a run
        `/rate <run_id> +` — thumbs up entire run
        `/rate <run_id> -` — thumbs down entire run
        `/rate <run_id> <step> +` — rate a specific step
        `/rate <run_id> + optional feedback` — with comment
        Also accepts: `up`/`down`, `yes`/`no`, 👍/👎
        """, gateway: msg.gateway)
    end
  end

  defp show_run_outcomes(run_id_str, msg) do
    case Integer.parse(run_id_str) do
      {run_id, ""} ->
        outcomes = AlexClaw.Workflows.list_run_outcomes(run_id)

        if outcomes == [] do
          Gateway.send_message("No outcomes found for run #{run_id}.", gateway: msg.gateway)
        else
          text =
            Enum.map_join(outcomes, "\n", fn o ->
              quality = case o.result_quality do
                "thumbs_up" -> "👍"
                "thumbs_down" -> "👎"
                _ -> "—"
              end

              "#{o.step_position}. *#{o.skill_name}* #{quality} (#{o.duration_ms || 0}ms)"
            end)

          Gateway.send_message("*Run #{run_id} outcomes*\n\n#{text}\n\nRate: `/rate #{run_id} 👍` or `/rate #{run_id} <step> 👎`", gateway: msg.gateway)
        end

      _ ->
        Gateway.send_message("Invalid run ID: `#{run_id_str}`", gateway: msg.gateway)
    end
  end

  defp rate_all_outcomes(run_id_str, quality, feedback, msg) do
    case Integer.parse(run_id_str) do
      {run_id, ""} ->
        outcomes = AlexClaw.Workflows.list_run_outcomes(run_id)

        if outcomes == [] do
          Gateway.send_message("No outcomes found for run #{run_id}.", gateway: msg.gateway)
        else
          Enum.each(outcomes, fn o ->
            AlexClaw.Workflows.annotate_outcome(o.id, quality, feedback)
          end)

          emoji = quality_emoji(quality)
          Gateway.send_message("#{emoji} Rated #{length(outcomes)} steps for run #{run_id}.", gateway: msg.gateway)
        end

      _ ->
        Gateway.send_message("Invalid run ID: `#{run_id_str}`", gateway: msg.gateway)
    end
  end

  defp rate_step_outcome(run_id_str, step_str, quality, feedback, msg) do
    with {run_id, ""} <- Integer.parse(run_id_str),
         {step_pos, ""} <- Integer.parse(step_str) do
      outcomes = AlexClaw.Workflows.list_run_outcomes(run_id)

      case Enum.find(outcomes, &(&1.step_position == step_pos)) do
        nil ->
          Gateway.send_message("Step #{step_pos} not found in run #{run_id}.", gateway: msg.gateway)

        outcome ->
          AlexClaw.Workflows.annotate_outcome(outcome.id, quality, feedback)
          emoji = quality_emoji(quality)
          Gateway.send_message("#{emoji} Rated step #{step_pos} (#{outcome.skill_name}) for run #{run_id}.", gateway: msg.gateway)
      end
    else
      _ -> Gateway.send_message("Usage: `/rate <run_id> <step> +|-`", gateway: msg.gateway)
    end
  end

  @thumbs_up_variants ~w(👍 + up yes ok good)
  @thumbs_down_variants ~w(👎 - down no bad nope)

  defp normalize_reaction(input) do
    clean = input |> String.trim() |> String.downcase()

    cond do
      clean in @thumbs_up_variants -> {:ok, "thumbs_up"}
      clean in @thumbs_down_variants -> {:ok, "thumbs_down"}
      String.contains?(clean, "👍") -> {:ok, "thumbs_up"}
      String.contains?(clean, "👎") -> {:ok, "thumbs_down"}
      true -> :error
    end
  end

  defp quality_emoji("thumbs_up"), do: "👍"
  defp quality_emoji("thumbs_down"), do: "👎"
  defp quality_emoji(_), do: "—"

  # --- LLM Status ---

  def dispatch(%Message{text: "/llm" <> _} = msg) do
    providers = [
      {"Gemini Flash", :light, "llm.gemini_api_key"},
      {"Gemini Pro", :medium, "llm.gemini_api_key"},
      {"Claude Haiku", :light, "llm.anthropic_api_key"},
      {"Claude Sonnet", :medium, "llm.anthropic_api_key"},
      {"Claude Opus", :heavy, "llm.anthropic_api_key"},
      {"Ollama", :local, nil},
      {"LM Studio", :local, nil}
    ]

    text =
      Enum.map_join(providers, "\n", fn {name, tier, key_path} ->
        status =
          cond do
            name == "Ollama" ->
              if Config.get("llm.ollama_enabled"), do: "enabled", else: "disabled"
            name == "LM Studio" ->
              if Config.get("llm.lmstudio_enabled"), do: "enabled", else: "disabled"
            key_path == nil ->
              "disabled"
            true ->
              key = Config.get(key_path) || ""
              if key != "", do: "configured", else: "no key"
          end

        "• *#{name}* (#{tier}) — #{status}"
      end)

    Gateway.send_message("*AlexClaw LLM Providers*\n\n#{text}", gateway: msg.gateway)
  end

  # --- GitHub ---

  def dispatch(%Message{text: "/github pr " <> rest} = msg) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [repo, pr] ->
        case Integer.parse(pr) do
          {pr_number, ""} ->
            AlexClaw.Skills.GitHubSecurityReview.review_pr(repo, pr_number, gateway: msg.gateway)
            Gateway.send_message("GitHub security review started for PR ##{pr_number} on #{repo}.", gateway: msg.gateway)

          _ ->
            Gateway.send_message("Invalid PR number: `#{pr}`\nUsage: /github pr owner/repo <number>", gateway: msg.gateway)
        end

      [repo] ->
        AlexClaw.Skills.GitHubSecurityReview.review_pr(repo, nil, gateway: msg.gateway)
        Gateway.send_message("GitHub security review started for latest PR on #{repo}.", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/github commit " <> rest} = msg) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [repo, sha] ->
        AlexClaw.Skills.GitHubSecurityReview.review_commit(repo, sha, gateway: msg.gateway)
        Gateway.send_message("GitHub security review started for commit #{String.slice(sha, 0, 8)} on #{repo}.", gateway: msg.gateway)

      _ ->
        Gateway.send_message("Usage: /github commit owner/repo <sha>", gateway: msg.gateway)
    end
  end

  # --- Coder ---

  def dispatch(%Message{text: "/coder " <> goal} = msg) do
    goal = String.trim(goal)
    Gateway.send_message("Generating skill: _#{goal}_...", gateway: msg.gateway)

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      AlexClaw.Skills.Coder.handle(goal, gateway: msg.gateway)
    end)
  end

  def dispatch(%Message{text: "/coder" <> _} = msg) do
    Gateway.send_message("""
    *Coder — autonomous skill generation*
    /coder <goal> — generate a dynamic skill from a natural language description

    Example: `/coder a skill that returns the current BEAM process count and memory usage`
    """, gateway: msg.gateway)
  end

  # --- Shell ---

  def dispatch(%Message{text: "/shell " <> command} = msg) do
    command = String.trim(command)
    if Config.get("shell.enabled") == true do
      case AuthCommands.require_2fa(msg, %{type: :shell_command, command: command},
             "Execute: `#{String.slice(command, 0, 80)}`") do
        :challenged -> :ok
        :proceed ->
          Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
            case AlexClaw.Skills.Shell.run(%{input: command}) do
              {:ok, result, _branch} -> Gateway.send_message(result, gateway: msg.gateway)
              {:error, reason} -> Gateway.send_message("Shell error: #{inspect(reason)}", gateway: msg.gateway)
            end
          end)
      end
    else
      Gateway.send_message("Shell commands are disabled. Enable in Admin > Config.", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/shell" <> _} = msg) do
    Gateway.send_message("""
    *Shell — container introspection*
    /shell <command> — execute a whitelisted command (2FA-gated)

    Examples: `df -h`, `ps aux`, `free -m`, `uptime`
    """, gateway: msg.gateway)
  end

  # --- Help ---

  def dispatch(%Message{text: "/help" <> _} = msg) do
    Gateway.send_message("""
    *AlexClaw commands*
    /ping — check if alive
    /status — system status
    /skills — list registered skills
    /llm — show LLM providers status
    /workflows — list all workflows
    /run <id or name> — run a workflow
    /runs — show active workflow runs
    /cancel <run\_id> — cancel a running workflow
    /rate <run\_id> — view/rate workflow step outcomes (+/- or up/down)
    /research <query> — deep research
    /search <query> — search the web
    /web <url> — summarize a web page
    /web <url> <question> — answer a question about a page
    /github pr <owner/repo> [pr\_number] — security review a PR
    /github commit <owner/repo> <sha> — security review a commit
    /tasks — list your Google Tasks
    /tasklists — list your task lists with IDs
    /task add <title> — add a new task
    /coder <goal> — generate a dynamic skill from a description
    /shell <command> — run whitelisted OS command (2FA-gated)
    /record <url> — start browser recording (returns noVNC link)
    /record stop <session\_id> — stop recording, get captured actions
    /replay <resource\_id> — replay a recorded automation
    /automate <url> — scrape and screenshot a URL via web-automator
    /connect google — connect Google Calendar/Tasks via OAuth
    /disconnect google — remove Google connection
    /setup 2fa — enable two-factor authentication
    /disable 2fa — disable two-factor authentication
    /help — this message
    _Anything else → conversation_
    """, gateway: msg.gateway)
  end

  # --- Catch-all: 2FA challenge response or conversational ---

  def dispatch(%Message{text: text} = msg) when is_binary(text) do
    trimmed = String.trim(text)

    if Regex.match?(~r/^\d{6}$/, trimmed) and AlexClaw.Auth.TOTP.pending_challenge?(msg.chat_id) do
      case AlexClaw.Auth.TOTP.resolve_challenge(msg.chat_id, trimmed) do
        {:ok, action} ->
          Gateway.send_message("Code verified. Executing...", chat_id: msg.chat_id, gateway: msg.gateway)
          AuthCommands.execute_2fa_action(action, msg)

        {:error, :invalid_code} ->
          Gateway.send_message("Invalid code. Try again (2 minutes remaining).", chat_id: msg.chat_id, gateway: msg.gateway)

        {:error, :challenge_expired} ->
          Gateway.send_message("Challenge expired. Please trigger the action again.", chat_id: msg.chat_id, gateway: msg.gateway)
      end
    else
      AlexClaw.Skills.Conversational.handle(msg)
    end
  end

  def dispatch(_other), do: :ignored
end
