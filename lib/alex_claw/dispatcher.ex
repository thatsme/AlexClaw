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
  alias AlexClaw.Dispatcher.{AuthCommands, AutomationCommands, SkillCommands}

  @spec dispatch(Message.t()) :: :ok | :ignored | term()
  def dispatch(%Message{text: "/start" <> _} = msg) do
    Gateway.send_message("🦇 *AlexClaw* is ready.\nType /help for commands.", gateway: msg.gateway)
  end

  def dispatch(%Message{text: "/ping" <> _} = msg) do
    Gateway.send_message("pong from `#{node()}`", chat_id: msg.chat_id, gateway: msg.gateway)
  end

  def dispatch(%Message{text: "/status" <> _} = msg) do
    uptime = :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
    memory = :erlang.memory(:total) |> div(1_048_576)

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

  def dispatch(%Message{text: "/research " <> query} = msg) do
    AlexClaw.Skills.Research.handle(String.trim(query), gateway: msg.gateway)
  end

  def dispatch(%Message{text: "/search " <> query} = msg) do
    AlexClaw.Skills.WebSearch.handle(String.trim(query), gateway: msg.gateway)
  end

  def dispatch(%Message{text: "/web " <> rest} = msg) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [url, question] ->
        AlexClaw.Skills.WebBrowse.handle(url, question, gateway: msg.gateway)

      [url] ->
        AlexClaw.Skills.WebBrowse.handle(url, nil, gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/skills" <> _} = msg) do
    text =
      AlexClaw.Workflows.SkillRegistry.list_all_with_type()
      |> Enum.map_join("\n", fn {name, module, type, perms, _routes} ->
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

  def dispatch(%Message{text: "/skill " <> _} = msg), do: SkillCommands.dispatch(msg)
  def dispatch(%Message{text: "/skill" <> _} = msg), do: SkillCommands.dispatch(msg)

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
        workflows
        |> Enum.map_join("\n", fn wf ->
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
          AlexClaw.Repo.get(AlexClaw.Workflows.Workflow, id)
          |> AlexClaw.Repo.preload([:steps, :resources])

        _ ->
          AlexClaw.Workflows.list_workflows()
          |> Enum.find(&(String.downcase(&1.name) == String.downcase(input)))
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
      providers
      |> Enum.map_join("\n", fn {name, tier, key_path} ->
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
    /skill load|unload|reload|create — manage dynamic skills
    /llm — show LLM providers status
    /workflows — list all workflows
    /run <id or name> — run a workflow
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
