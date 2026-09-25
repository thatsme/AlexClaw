defmodule AlexClaw.Dispatcher do
  @moduledoc """
  Routes incoming messages and scheduled events to the correct skill.
  Pattern matches on message content — no LLM for routing.

  Command groups are delegated to focused modules:
  - `AutomationCommands` — /record, /replay, /automate
  - `AuthCommands` — 2FA setup/confirm/disable, OAuth connect/disconnect
  """
  require Logger

  alias AlexClaw.Auth.Challenge
  alias AlexClaw.Config
  alias AlexClaw.Dispatcher.{AuthCommands, AutomationCommands, CommandParser}
  alias AlexClaw.Gateway
  alias AlexClaw.Message
  alias AlexClaw.Repo
  alias AlexClaw.SkillSupervisor

  alias AlexClaw.Skills.{
    Coder,
    Conversational,
    GitHubSecurityReview,
    GoogleTasks,
    Research,
    Shell,
    WebBrowse,
    WebSearch
  }

  alias AlexClaw.Workflows
  alias Workflows.{Executor, SkillRegistry, Workflow}

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

    Gateway.send_message(
      """
      *AlexClaw* status
      Uptime: #{uptime}s
      Memory: #{memory} MB
      Skills running: #{DynamicSupervisor.count_children(SkillSupervisor).active}
      """,
      gateway: msg.gateway
    )
  end

  def dispatch(%Message{text: "/task add " <> title} = msg) do
    case GoogleTasks.run(%{
           config: %{"action" => "add"},
           input: String.trim(title)
         }) do
      {:ok, result, _branch} ->
        Gateway.send_message(result, gateway: msg.gateway)

      {:error, reason} ->
        Gateway.send_message("Failed to add task: #{inspect(reason)}", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/tasklists" <> _} = msg) do
    case GoogleTasks.run(%{config: %{"action" => "lists"}}) do
      {:ok, result, _branch} ->
        Gateway.send_message("*Your Task Lists*\n\n#{result}", gateway: msg.gateway)

      {:error, reason} ->
        Gateway.send_message("Failed to fetch task lists: #{inspect(reason)}",
          gateway: msg.gateway
        )
    end
  end

  def dispatch(%Message{text: "/tasks" <> _} = msg) do
    case GoogleTasks.run(%{config: %{"action" => "list"}}) do
      {:ok, result, _branch} ->
        Gateway.send_message("*Your Tasks*\n\n#{result}", gateway: msg.gateway)

      {:error, reason} ->
        Gateway.send_message("Failed to fetch tasks: #{inspect(reason)}", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/research " <> raw} = msg) do
    tiered_command(msg, raw, %{
      label: "Research",
      report_label: "Research",
      prefix: "skill.research",
      default_tier: "medium",
      usage: "Usage: /research [--tier light|medium|heavy|local] [--provider name] <query>",
      handler: &Research.handle/2
    })
  end

  def dispatch(%Message{text: "/search " <> raw} = msg) do
    tiered_command(msg, raw, %{
      label: "Search",
      report_label: "Web Search",
      prefix: "skill.web_search",
      default_tier: "medium",
      usage: "Usage: /search [--tier light|medium|heavy|local] [--provider name] <query>",
      handler: &WebSearch.handle/2
    })
  end

  def dispatch(%Message{text: "/web " <> raw} = msg) do
    {rest, flags} = CommandParser.parse(String.trim(raw))

    if rest == "" and Keyword.has_key?(flags, :tier) do
      new_tier = Keyword.get(flags, :tier)
      Config.set("skill.web_browse.tier", new_tier)

      if provider = Keyword.get(flags, :provider) do
        Config.set("skill.web_browse.provider", provider)

        Gateway.send_message("Browse defaults saved: tier=#{new_tier}, provider=#{provider}",
          gateway: msg.gateway
        )
      else
        Gateway.send_message("Browse default tier saved: #{new_tier}", gateway: msg.gateway)
      end
    else
      tier = CommandParser.resolve_tier(flags, "skill.web_browse.tier", "light")
      provider = CommandParser.resolve_provider(flags, "skill.web_browse.provider")

      case String.split(rest, " ", parts: 2) do
        [url, question] ->
          Gateway.send_message("Browse (tier: #{tier}, provider: #{provider})",
            gateway: msg.gateway
          )

          WebBrowse.handle(url, question,
            tier: tier,
            provider: provider,
            gateway: msg.gateway
          )

        [url] ->
          Gateway.send_message("Browse (tier: #{tier}, provider: #{provider})",
            gateway: msg.gateway
          )

          WebBrowse.handle(url, nil,
            tier: tier,
            provider: provider,
            gateway: msg.gateway
          )
      end
    end
  end

  def dispatch(%Message{text: "/skills" <> _} = msg) do
    text =
      Enum.map_join(SkillRegistry.list_all_with_type(), "\n", fn {name, module, type, perms,
                                                                  _routes, _ext} ->
        desc =
          if function_exported?(module, :description, 0),
            do: module.description(),
            else: "—"

        tag = if type == :dynamic, do: " `[dynamic]`", else: ""

        perm_text =
          if type == :dynamic and is_list(perms),
            do: " — permissions: #{Enum.join(perms, ", ")}",
            else: ""

        "• *#{name}*#{tag} — #{desc}#{perm_text}"
      end)

    Gateway.send_message("*AlexClaw Skills*\n\n#{text}", gateway: msg.gateway)
  end

  # --- Delegated Command Groups ---

  def dispatch(%Message{text: "/skill" <> _} = msg) do
    Gateway.send_message(
      "Skill management is only available from the Admin UI.\n2FA verification will be sent here when actions are performed.",
      gateway: msg.gateway
    )
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
    send_workflow_list(Workflows.list_workflows(), msg)
  end

  def dispatch(%Message{text: "/run " <> rest} = msg) do
    input = String.trim(rest)
    run_workflow(find_workflow(input), input, msg)
  end

  def dispatch(%Message{text: "/runs" <> _} = msg) do
    active = Workflows.list_active_runs()

    if active == [] do
      Gateway.send_message("No workflows currently running.", gateway: msg.gateway)
    else
      text =
        Enum.map_join(active, "\n", fn run ->
          elapsed = DateTime.diff(DateTime.utc_now(), run.started_at)
          "• *#{run.workflow_name}* (run #{run.run_id}) — #{elapsed}s"
        end)

      Gateway.send_message("*Active Runs*\n\n#{text}\n\nCancel with: `/cancel <run_id>`",
        gateway: msg.gateway
      )
    end
  end

  def dispatch(%Message{text: "/cancel " <> rest} = msg) do
    case Integer.parse(String.trim(rest)) do
      {run_id, ""} ->
        case Workflows.cancel_run(run_id) do
          :ok ->
            Gateway.send_message("Run #{run_id} cancelled.", gateway: msg.gateway)

          {:error, :not_found} ->
            Gateway.send_message("Run #{run_id} not found or already finished.",
              gateway: msg.gateway
            )
        end

      _ ->
        Gateway.send_message("Usage: `/cancel <run_id>`", gateway: msg.gateway)
    end
  end

  # --- Outcome Rating ---

  @rate_usage """
  *Rate workflow outcomes*
  `/rate <run_id>` \u2014 show steps for a run
  `/rate <run_id> +` \u2014 thumbs up entire run
  `/rate <run_id> -` \u2014 thumbs down entire run
  `/rate <run_id> <step> +` \u2014 rate a specific step
  `/rate <run_id> + optional feedback` \u2014 with comment
  Also accepts: `up`/`down`, `yes`/`no`, \u{1F44D}/\u{1F44E}
  """

  def dispatch(%Message{text: "/rate " <> rest} = msg) do
    rest
    |> String.trim()
    |> String.split(" ", parts: 3)
    |> rate_command(msg)
  end

  defp rate_command([run_id_str], msg), do: show_run_outcomes(run_id_str, msg)

  defp rate_command([run_id_str, raw_reaction], msg) do
    rate_run(normalize_reaction(raw_reaction), run_id_str, raw_reaction, nil, msg)
  end

  # Three parts are ambiguous: `run_id reaction feedback` or `run_id step reaction`.
  # The second token decides which.
  defp rate_command([run_id_str, second, third], msg) do
    rate_run_or_step(normalize_reaction(second), run_id_str, second, third, msg)
  end

  defp rate_command(_parts, msg), do: Gateway.send_message(@rate_usage, gateway: msg.gateway)

  defp rate_run({:ok, quality}, run_id_str, _raw, feedback, msg) do
    rate_all_outcomes(run_id_str, quality, feedback, msg)
  end

  defp rate_run(:error, _run_id_str, raw, _feedback, msg) do
    Gateway.send_message(
      "Unknown rating: `#{raw}`. Use `+`/`-`, `up`/`down`, or \u{1F44D}/\u{1F44E}.",
      gateway: msg.gateway
    )
  end

  defp rate_run_or_step({:ok, quality}, run_id_str, _second, third, msg) do
    rate_all_outcomes(run_id_str, quality, third, msg)
  end

  defp rate_run_or_step(:error, run_id_str, second, third, msg) do
    rate_step(normalize_reaction(third), run_id_str, second, msg)
  end

  defp rate_step({:ok, quality}, run_id_str, step_str, msg) do
    rate_step_outcome(run_id_str, step_str, quality, nil, msg)
  end

  defp rate_step(:error, _run_id_str, _step_str, msg) do
    Gateway.send_message("Unknown rating. Use `+`/`-`, `up`/`down`, or \u{1F44D}/\u{1F44E}.",
      gateway: msg.gateway
    )
  end

  defp show_run_outcomes(run_id_str, msg) do
    run_id_str
    |> Integer.parse()
    |> show_run_outcomes(run_id_str, msg)
  end

  defp show_run_outcomes({run_id, ""}, _raw, msg) do
    send_outcomes(Workflows.list_run_outcomes(run_id), run_id, msg)
  end

  defp show_run_outcomes(_parsed, raw, msg) do
    Gateway.send_message("Invalid run ID: `#{raw}`", gateway: msg.gateway)
  end

  defp send_outcomes([], run_id, msg) do
    Gateway.send_message("No outcomes found for run #{run_id}.", gateway: msg.gateway)
  end

  defp send_outcomes(outcomes, run_id, msg) do
    text = Enum.map_join(outcomes, "\n", &outcome_line/1)

    Gateway.send_message(
      "*Run #{run_id} outcomes*\n\n#{text}\n\nRate: `/rate #{run_id} \u{1F44D}` or `/rate #{run_id} <step> \u{1F44E}`",
      gateway: msg.gateway
    )
  end

  defp outcome_line(outcome) do
    "#{outcome.step_position}. *#{outcome.skill_name}* #{quality_emoji(outcome.result_quality)} (#{outcome.duration_ms || 0}ms)"
  end

  defp rate_all_outcomes(run_id_str, quality, feedback, msg) do
    run_id_str
    |> Integer.parse()
    |> rate_all_outcomes(run_id_str, quality, feedback, msg)
  end

  defp rate_all_outcomes({run_id, ""}, _raw, quality, feedback, msg) do
    annotate_outcomes(Workflows.list_run_outcomes(run_id), run_id, quality, feedback, msg)
  end

  defp rate_all_outcomes(_parsed, raw, _quality, _feedback, msg) do
    Gateway.send_message("Invalid run ID: `#{raw}`", gateway: msg.gateway)
  end

  defp annotate_outcomes([], run_id, _quality, _feedback, msg) do
    Gateway.send_message("No outcomes found for run #{run_id}.", gateway: msg.gateway)
  end

  defp annotate_outcomes(outcomes, run_id, quality, feedback, msg) do
    Enum.each(outcomes, &Workflows.annotate_outcome(&1.id, quality, feedback))

    Gateway.send_message(
      "#{quality_emoji(quality)} Rated #{length(outcomes)} steps for run #{run_id}.",
      gateway: msg.gateway
    )
  end

  defp rate_step_outcome(run_id_str, step_str, quality, feedback, msg) do
    with {run_id, ""} <- Integer.parse(run_id_str),
         {step_pos, ""} <- Integer.parse(step_str) do
      outcomes = Workflows.list_run_outcomes(run_id)

      case Enum.find(outcomes, &(&1.step_position == step_pos)) do
        nil ->
          Gateway.send_message("Step #{step_pos} not found in run #{run_id}.",
            gateway: msg.gateway
          )

        outcome ->
          Workflows.annotate_outcome(outcome.id, quality, feedback)
          emoji = quality_emoji(quality)

          Gateway.send_message(
            "#{emoji} Rated step #{step_pos} (#{outcome.skill_name}) for run #{run_id}.",
            gateway: msg.gateway
          )
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

  @llm_providers [
    {"Gemini Flash", :light, "llm.gemini_api_key"},
    {"Gemini Pro", :medium, "llm.gemini_api_key"},
    {"Claude Haiku", :light, "llm.anthropic_api_key"},
    {"Claude Sonnet", :medium, "llm.anthropic_api_key"},
    {"Claude Opus", :heavy, "llm.anthropic_api_key"},
    {"Ollama", :local, nil},
    {"LM Studio", :local, nil}
  ]

  def dispatch(%Message{text: "/llm" <> _} = msg) do
    text = Enum.map_join(@llm_providers, "\n", &provider_line/1)
    Gateway.send_message("*AlexClaw LLM Providers*\n\n#{text}", gateway: msg.gateway)
  end

  defp provider_line({name, tier, key_path}) do
    "\u2022 *#{name}* (#{tier}) \u2014 #{provider_status(name, key_path)}"
  end

  defp provider_status("Ollama", _key_path), do: toggle_status("llm.ollama_enabled")
  defp provider_status("LM Studio", _key_path), do: toggle_status("llm.lmstudio_enabled")
  defp provider_status(_name, nil), do: "disabled"
  defp provider_status(_name, key_path), do: key_status(Config.get(key_path) || "")

  defp toggle_status(config_key) do
    if Config.get(config_key), do: "enabled", else: "disabled"
  end

  defp key_status(""), do: "no key"
  defp key_status(_key), do: "configured"

  # --- GitHub ---

  def dispatch(%Message{text: "/github pr " <> rest} = msg) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [repo, pr] ->
        case Integer.parse(pr) do
          {pr_number, ""} ->
            GitHubSecurityReview.review_pr(repo, pr_number, gateway: msg.gateway)

            Gateway.send_message(
              "GitHub security review started for PR ##{pr_number} on #{repo}.",
              gateway: msg.gateway
            )

          _ ->
            Gateway.send_message(
              "Invalid PR number: `#{pr}`\nUsage: /github pr owner/repo <number>",
              gateway: msg.gateway
            )
        end

      [repo] ->
        GitHubSecurityReview.review_pr(repo, nil, gateway: msg.gateway)

        Gateway.send_message("GitHub security review started for latest PR on #{repo}.",
          gateway: msg.gateway
        )
    end
  end

  def dispatch(%Message{text: "/github commit " <> rest} = msg) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [repo, sha] ->
        GitHubSecurityReview.review_commit(repo, sha, gateway: msg.gateway)

        Gateway.send_message(
          "GitHub security review started for commit #{String.slice(sha, 0, 8)} on #{repo}.",
          gateway: msg.gateway
        )

      _ ->
        Gateway.send_message("Usage: /github commit owner/repo <sha>", gateway: msg.gateway)
    end
  end

  # --- Coder ---

  def dispatch(%Message{text: "/coder " <> goal} = msg) do
    goal = String.trim(goal)
    Gateway.send_message("Generating skill: _#{goal}_...", gateway: msg.gateway)

    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      Coder.handle(goal, gateway: msg.gateway)
    end)
  end

  def dispatch(%Message{text: "/coder" <> _} = msg) do
    Gateway.send_message(
      """
      *Coder — autonomous skill generation*
      /coder <goal> — generate a dynamic skill from a natural language description

      Example: `/coder a skill that returns the current BEAM process count and memory usage`
      """,
      gateway: msg.gateway
    )
  end

  # --- Shell ---

  def dispatch(%Message{text: "/shell " <> command} = msg) do
    run_shell(Config.get("shell.enabled"), String.trim(command), msg)
  end

  defp run_shell(true, command, msg) do
    msg
    |> AuthCommands.require_2fa(
      %{type: :shell_command, command: command},
      "Execute: `#{String.slice(command, 0, 80)}`"
    )
    |> shell_after_2fa(command, msg)
  end

  defp run_shell(_enabled, _command, msg) do
    Gateway.send_message("Shell commands are disabled. Enable in Admin > Config.",
      gateway: msg.gateway
    )
  end

  defp shell_after_2fa(:challenged, _command, _msg), do: :ok
  # The chat was told it is locked.
  defp shell_after_2fa({:locked, _minutes}, _command, _msg), do: :ok

  defp shell_after_2fa(:no_2fa, _command, msg) do
    Gateway.send_message("Enable 2FA first, in the admin UI (Services page).",
      gateway: msg.gateway
    )
  end

  def dispatch(%Message{text: "/shell" <> _} = msg) do
    Gateway.send_message(
      """
      *Shell — container introspection*
      /shell <command> — execute a whitelisted command (2FA-gated)

      Examples: `df -h`, `ps aux`, `free -m`, `uptime`
      """,
      gateway: msg.gateway
    )
  end

  # --- Help ---

  def dispatch(%Message{text: "/help" <> _} = msg) do
    Gateway.send_message(
      """
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
      /help — this message
      _Anything else → conversation_
      """,
      gateway: msg.gateway
    )
  end

  # --- Catch-all: 2FA challenge response or conversational ---

  def dispatch(%Message{text: text} = msg) when is_binary(text) do
    trimmed = String.trim(text)

    if Regex.match?(~r/^\d{6}$/, trimmed) and Challenge.pending?(msg.chat_id) do
      msg.chat_id
      |> Challenge.resolve(trimmed)
      |> answer_code(msg)
    else
      Conversational.handle(msg)
    end
  end

  def dispatch(_other), do: :ignored

  # Every result of Challenge.resolve/2 ends in a reply. A code that meets a
  # lock was never checked, so the reply says the lock, not "invalid code".
  defp answer_code({:ok, action}, msg) do
    reply("Code verified. Executing...", msg)
    Phoenix.PubSub.broadcast(AlexClaw.PubSub, "services:totp", {:totp_verified, action})
    AuthCommands.execute_2fa_action(action, msg)
  end

  defp answer_code({:error, :invalid_code}, msg),
    do: reply("Invalid code. Try again (2 minutes remaining).", msg)

  defp answer_code({:error, :challenge_expired}, msg),
    do: reply("Challenge expired. Please trigger the action again.", msg)

  defp answer_code({:error, :too_many_attempts}, msg),
    do: reply("Too many invalid codes. Challenge cancelled — trigger the action again.", msg)

  defp answer_code({:error, :no_challenge}, msg),
    do: reply("No pending challenge. Trigger the action again.", msg)

  defp answer_code({:error, :locked_session}, msg) do
    reply(
      "Code not checked: this chat is locked after too many wrong codes. " <>
        "Try again in #{lock_minutes(msg.chat_id)}.",
      msg
    )
  end

  defp answer_code({:error, :locked_instance}, msg) do
    reply(
      "Code not checked: code entry is locked everywhere after too many wrong codes. " <>
        "Try again in #{lock_minutes(msg.chat_id)}.",
      msg
    )
  end

  defp answer_code({:error, reason}, msg) do
    Logger.warning("2FA code not resolved: #{inspect(reason)}")
    reply("The code could not be checked. Trigger the action again.", msg)
  end

  defp reply(text, msg),
    do: Gateway.send_message(text, chat_id: msg.chat_id, gateway: msg.gateway)

  defp lock_minutes(chat_id), do: chat_id |> Challenge.lock() |> minutes_left()

  defp minutes_left({:locked, 1}), do: "1 minute"
  defp minutes_left({:locked, minutes}), do: "#{minutes} minutes"
  # Lifted between the refusal and this reply.
  defp minutes_left(:ok), do: "1 minute"

  # --- Tier/provider commands (/research, /search) ---
  #
  # Both accept the same flag grammar: `--tier` alone reports or saves the
  # default, a bare command prints usage, anything else runs the skill.

  defp tiered_command(msg, raw, spec) do
    {query, flags} = CommandParser.parse(String.trim(raw))
    tiered_command(msg, spec, query, flags, Keyword.get(flags, :tier))
  end

  defp tiered_command(msg, spec, _query, _flags, :query) do
    tier = Config.get("#{spec.prefix}.tier") || spec.default_tier
    provider = Config.get("#{spec.prefix}.provider") || "auto"

    Gateway.send_message("#{spec.report_label}: tier=#{tier}, provider=#{provider}",
      gateway: msg.gateway
    )
  end

  defp tiered_command(msg, spec, "", flags, tier) when not is_nil(tier) do
    save_tier_defaults(msg, spec, tier, Keyword.get(flags, :provider))
  end

  defp tiered_command(msg, spec, "", _flags, _tier) do
    Gateway.send_message(spec.usage, gateway: msg.gateway)
  end

  defp tiered_command(msg, spec, query, flags, _tier) do
    tier = CommandParser.resolve_tier(flags, "#{spec.prefix}.tier", spec.default_tier)
    provider = CommandParser.resolve_provider(flags, "#{spec.prefix}.provider")

    Gateway.send_message("#{spec.label} (tier: #{tier}, provider: #{provider})",
      gateway: msg.gateway
    )

    spec.handler.(query, tier: tier, provider: provider, gateway: msg.gateway)
  end

  defp save_tier_defaults(msg, spec, tier, nil) do
    Config.set("#{spec.prefix}.tier", tier)
    Gateway.send_message("#{spec.label} default tier saved: #{tier}", gateway: msg.gateway)
  end

  defp save_tier_defaults(msg, spec, tier, provider) do
    Config.set("#{spec.prefix}.tier", tier)
    Config.set("#{spec.prefix}.provider", provider)

    Gateway.send_message("#{spec.label} defaults saved: tier=#{tier}, provider=#{provider}",
      gateway: msg.gateway
    )
  end

  # --- Workflow listing and launching (/workflows, /run) ---

  defp send_workflow_list([], msg) do
    Gateway.send_message("No workflows configured.", gateway: msg.gateway)
  end

  defp send_workflow_list(workflows, msg) do
    text = Enum.map_join(workflows, "\n", &workflow_line/1)

    Gateway.send_message("*AlexClaw Workflows*\n\n#{text}\n\nRun with: `/run <id>`",
      gateway: msg.gateway
    )
  end

  defp workflow_line(wf) do
    "\u2022 *#{wf.name}* (#{workflow_status(wf)}#{workflow_schedule(wf)}) \u2014 id: #{wf.id}"
  end

  defp workflow_status(%{enabled: true}), do: "enabled"
  defp workflow_status(_wf), do: "disabled"

  defp workflow_schedule(%{schedule: schedule}) when is_binary(schedule) and schedule != "" do
    " `#{schedule}`"
  end

  defp workflow_schedule(_wf), do: ""

  defp find_workflow(input) do
    input
    |> Integer.parse()
    |> find_workflow(input)
  end

  defp find_workflow({id, ""}, _input) do
    Repo.preload(Repo.get(Workflow, id), [:steps, :resources])
  end

  defp find_workflow(_parsed, input) do
    Enum.find(
      Workflows.list_workflows(),
      &(String.downcase(&1.name) == String.downcase(input))
    )
  end

  defp run_workflow(nil, input, msg) do
    Gateway.send_message(
      "Workflow not found: `#{input}`\nUse /workflows to see available workflows.",
      gateway: msg.gateway
    )
  end

  defp run_workflow(workflow, _input, msg) do
    launch_workflow(workflow, msg, AlexClaw.Workflows.Workflow.protected?(workflow))
  end

  defp launch_workflow(workflow, msg, true) do
    msg
    |> AuthCommands.require_2fa(
      %{type: :run_workflow, workflow_id: workflow.id},
      "Run workflow: *#{workflow.name}*"
    )
    |> resume_after_2fa(workflow, msg)
  end

  defp launch_workflow(workflow, msg, _requires_2fa), do: start_workflow(workflow, msg)

  defp resume_after_2fa(:challenged, _workflow, _msg), do: :ok
  # The chat was told it is locked.
  defp resume_after_2fa({:locked, _minutes}, _workflow, _msg), do: :ok

  defp resume_after_2fa(:no_2fa, _workflow, msg) do
    Gateway.send_message("Enable 2FA first, in the admin UI (Services page).",
      gateway: msg.gateway
    )
  end

  defp start_workflow(workflow, msg) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      Executor.run(workflow.id)
    end)

    Gateway.send_message("Workflow '#{workflow.name}' started.", gateway: msg.gateway)
  end
end
