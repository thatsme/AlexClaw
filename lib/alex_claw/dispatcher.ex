defmodule AlexClaw.Dispatcher do
  @moduledoc """
  Routes incoming messages and scheduled events to the correct skill.
  Pattern matches on message content — no LLM for routing.

  A chat operates AlexClaw; it never authors it (0.4.0 S5b): commands that
  wrote a setting, recorded or replayed a page, generated a skill or ran a
  shell command answer where that is done instead. Workflow runs go through
  `AlexClaw.ControlPlane.perform/3`. `AuthCommands` answers the 2FA and
  connection commands, and approves a protected run with a code.
  """
  require Logger

  alias AlexClaw.Auth.Challenge
  alias AlexClaw.Config
  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Dispatcher.{AuthCommands, CommandParser}
  alias AlexClaw.Gateway
  alias AlexClaw.{Memory, Message}
  alias AlexClaw.Repo
  alias AlexClaw.SkillSupervisor

  alias AlexClaw.Workflows
  alias Workflows.{SkillRegistry, Workflow}

  @doc """
  Handle a message from a gateway. Only the owner is answered, as set in the
  admin UI (`:set_gateway_owner`): for Telegram the chat `telegram.chat_id`;
  for Discord the user `discord.owner_user_id` in the channel
  `discord.channel_id` — a channel has members, and any of them could
  otherwise command the agent (S8 M10). With no owner set, every message is
  ignored; a message never makes its chat, or its sender, the owner.
  """
  @spec dispatch(Message.t() | term()) :: :ok | :ignored | term()
  def dispatch(%Message{} = msg), do: msg |> owner?() |> routed(msg)
  def dispatch(_other), do: :ignored

  defp routed(true, msg), do: route(msg)

  defp routed(false, msg) do
    Logger.warning("Ignored a message from chat #{msg.chat_id}: not the owner chat")
    :ignored
  end

  defp owner?(%Message{gateway: :discord, chat_id: chat_id, user_id: user_id}),
    do:
      owner_chat?(Config.get("discord.channel_id"), chat_id) and
        owner_chat?(Config.get("discord.owner_user_id"), user_id)

  defp owner?(%Message{chat_id: chat_id, gateway: gateway}),
    do: owner_chat?(Config.get(owner_key(gateway)), chat_id)

  defp owner_key(_gateway), do: "telegram.chat_id"

  defp owner_chat?(owner, _chat_id) when owner in [nil, ""], do: false
  defp owner_chat?(_owner, nil), do: false
  defp owner_chat?(owner, chat_id), do: to_string(owner) == to_string(chat_id)

  defp route(%Message{text: "/start" <> _} = msg) do
    Gateway.send_message("🦇 *AlexClaw* is ready.\nType /help for commands.", gateway: msg.gateway)
  end

  defp route(%Message{text: "/ping" <> _} = msg) do
    Gateway.send_message("pong from `#{node()}`", chat_id: msg.chat_id, gateway: msg.gateway)
  end

  defp route(%Message{text: "/status" <> _} = msg) do
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

  defp route(%Message{text: "/task add " <> title} = msg) do
    "google_tasks"
    |> run_skill(%{config: %{"action" => "add"}, input: String.trim(title)}, msg)
    |> answer(msg, "", "Failed to add task")
  end

  defp route(%Message{text: "/tasklists" <> _} = msg) do
    "google_tasks"
    |> run_skill(%{config: %{"action" => "lists"}}, msg)
    |> answer(msg, "*Your Task Lists*\n\n", "Failed to fetch task lists")
  end

  defp route(%Message{text: "/tasks" <> _} = msg) do
    "google_tasks"
    |> run_skill(%{config: %{"action" => "list"}}, msg)
    |> answer(msg, "*Your Tasks*\n\n", "Failed to fetch tasks")
  end

  defp route(%Message{text: "/research " <> raw} = msg) do
    tiered_command(msg, raw, %{
      label: "Research",
      report_label: "Research",
      tier_key: "skill.research.tier",
      provider_key: "skill.research.provider",
      default_tier: "medium",
      usage: "Usage: /research [--tier light|medium|heavy|local] [--provider name] <query>",
      skill: "research"
    })
  end

  defp route(%Message{text: "/search " <> raw} = msg) do
    tiered_command(msg, raw, %{
      label: "Search",
      report_label: "Web Search",
      tier_key: "skill.web_search.tier",
      provider_key: "skill.web_search.provider",
      default_tier: "medium",
      usage: "Usage: /search [--tier light|medium|heavy|local] [--provider name] <query>",
      skill: "web_search"
    })
  end

  defp route(%Message{text: "/web " <> raw} = msg) do
    {rest, flags} = CommandParser.parse(String.trim(raw))

    if rest == "" and Keyword.has_key?(flags, :tier) do
      defaults_elsewhere(msg)
    else
      tier = CommandParser.resolve_tier(flags, "skill.web_browse.tier", "light")
      provider = CommandParser.resolve_provider(flags, "skill.web_browse.provider")

      Gateway.send_message("Browse (tier: #{tier}, provider: #{provider})", gateway: msg.gateway)

      "web_browse"
      |> run_skill(
        %{
          config: browse_config(String.split(rest, " ", parts: 2)),
          llm_tier: to_string(tier),
          llm_provider: provider
        },
        msg
      )
      |> answer(msg, "", "Failed")
    end
  end

  defp route(%Message{text: "/skills" <> _} = msg) do
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

  defp route(%Message{text: "/skill" <> _} = msg) do
    Gateway.send_message(
      "Skill management is only available from the Admin UI.\n2FA verification will be sent here when actions are performed.",
      gateway: msg.gateway
    )
  end

  # Recording, replaying and automating a page start a browser session, and
  # a recording can later hold a login: authoring, done in the admin UI.
  defp route(%Message{text: "/" <> command} = msg)
       when binary_part(command, 0, 6) in ["record", "replay"] or
              binary_part(command, 0, 8) == "automate" do
    Gateway.send_message(
      "Recordings are made, replayed and automated in the admin UI (Resources page), not over a chat.",
      gateway: msg.gateway
    )
  end

  defp route(%Message{text: "/setup 2fa" <> _} = msg), do: AuthCommands.dispatch(msg)
  defp route(%Message{text: "/confirm 2fa " <> _} = msg), do: AuthCommands.dispatch(msg)
  defp route(%Message{text: "/disable 2fa" <> _} = msg), do: AuthCommands.dispatch(msg)
  defp route(%Message{text: "/connect" <> _} = msg), do: AuthCommands.dispatch(msg)
  defp route(%Message{text: "/disconnect" <> _} = msg), do: AuthCommands.dispatch(msg)

  # --- Workflows ---

  defp route(%Message{text: "/workflows" <> _} = msg) do
    send_workflow_list(Workflows.list_workflows(), msg)
  end

  defp route(%Message{text: "/run " <> rest} = msg) do
    input = String.trim(rest)
    run_workflow(find_workflow(input), input, msg)
  end

  defp route(%Message{text: "/runs" <> _} = msg) do
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

  defp route(%Message{text: "/cancel " <> rest} = msg) do
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

  defp route(%Message{text: "/rate " <> rest} = msg) do
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

  defp route(%Message{text: "/llm" <> _} = msg) do
    text = Enum.map_join(@llm_providers, "\n", &provider_line/1)
    Gateway.send_message("*AlexClaw LLM Providers*\n\n#{text}", gateway: msg.gateway)
  end

  defp provider_line({name, tier, key_path}) do
    "\u2022 *#{name}* (#{tier}) \u2014 #{provider_status(name, key_path)}"
  end

  defp provider_status("Ollama", _key_path), do: toggle_status("llm.ollama_enabled")
  defp provider_status("LM Studio", _key_path), do: toggle_status("llm.lmstudio_enabled")
  defp provider_status(_name, nil), do: "disabled"
  defp provider_status(_name, key_path), do: key_status(Config.secret_set_at(key_path))

  defp toggle_status(config_key) do
    if Config.get(config_key), do: "enabled", else: "disabled"
  end

  defp key_status(nil), do: "no key"
  defp key_status(_set_at), do: "configured"

  # --- GitHub ---

  defp route(%Message{text: "/github pr " <> rest} = msg) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [repo, pr] ->
        case Integer.parse(pr) do
          {pr_number, ""} ->
            review(%{"mode" => "specific_pr", "repo" => repo, "pr_number" => pr_number}, msg)

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
        review(%{"mode" => "latest_pr", "repo" => repo}, msg)

        Gateway.send_message("GitHub security review started for latest PR on #{repo}.",
          gateway: msg.gateway
        )
    end
  end

  defp route(%Message{text: "/github commit " <> rest} = msg) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [repo, sha] ->
        review(%{"mode" => "specific_commit", "repo" => repo, "commit_sha" => sha}, msg)

        Gateway.send_message(
          "GitHub security review started for commit #{String.slice(sha, 0, 8)} on #{repo}.",
          gateway: msg.gateway
        )

      _ ->
        Gateway.send_message("Usage: /github commit owner/repo <sha>", gateway: msg.gateway)
    end
  end

  # --- Coder ---

  defp route(%Message{text: "/coder" <> _} = msg) do
    Gateway.send_message(
      "Skills are generated in the admin UI (Forge page), not over a chat.",
      gateway: msg.gateway
    )
  end

  # --- Shell ---

  # A shell command from a chat is a protected workflow: a shell step in a
  # workflow marked "requires 2FA" in the admin UI, run here with /run and a
  # code.
  defp route(%Message{text: "/shell" <> _} = msg) do
    Gateway.send_message(
      "A shell command from a chat is a protected workflow, run with a code: add a shell " <>
        "step to a workflow that requires 2FA in the admin UI (Workflows page), then /run it.",
      gateway: msg.gateway
    )
  end

  # --- Help ---

  defp route(%Message{text: "/help" <> _} = msg) do
    Gateway.send_message(
      """
      *AlexClaw commands*
      /ping — check if alive
      /status — system status
      /skills — list registered skills
      /llm — show LLM providers status
      /workflows — list all workflows
      /run <id or name> — run a workflow (one that requires 2FA asks for a code)
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
      /help — this message
      _Anything else → conversation_
      """,
      gateway: msg.gateway
    )
  end

  # --- Catch-all: 2FA challenge response or conversational ---

  defp route(%Message{text: text} = msg) when is_binary(text) do
    trimmed = String.trim(text)

    if Regex.match?(~r/^\d{6}$/, trimmed) and Challenge.pending?(msg.chat_id) do
      msg.chat_id
      |> Challenge.pending_action()
      |> approve(msg)
    else
      "conversational"
      |> run_skill(%{input: msg.text}, msg)
      |> conversed(msg)
    end
  end

  defp route(_other), do: :ignored

  # The exchange is remembered, as a conversation always was.
  defp conversed({:ok, response, _branch}, msg) when is_binary(response) do
    source = to_string(msg.gateway || "chat")
    Memory.store(:conversation, "User: #{msg.text}", source: source)
    Memory.store(:conversation, "AlexClaw: #{response}", source: source)
    Gateway.send_message(response, gateway: msg.gateway)
  end

  defp conversed(_failed, msg),
    do: Gateway.send_message("Something went wrong. Try again.", gateway: msg.gateway)

  # The code approves the action the chat's challenge is waiting for — a
  # protected run, nothing else — and is checked when it is performed.
  defp approve({:ok, action}, msg),
    do: action |> AuthCommands.execute_2fa_action(msg) |> answer_code(msg)

  defp approve(:error, msg), do: answer_code({:error, :no_challenge}, msg)

  # Every result ends in a reply. A code that meets a lock was never checked,
  # so the reply says the lock, not "invalid code".
  defp answer_code({:ok, {:started, workflow}}, msg),
    do: reply("Code verified. Workflow '#{workflow.name}' started.", msg)

  defp answer_code({:error, :not_chat_approvable}, msg),
    do: reply("That can only be approved in the admin UI.", msg)

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
  # Both accept the same flag grammar: `--tier` alone reports the default (a
  # tier after it is refused: defaults are set in the admin UI), a bare
  # command prints usage, anything else runs the skill.

  defp tiered_command(msg, raw, spec) do
    {query, flags} = CommandParser.parse(String.trim(raw))
    tiered_command(msg, spec, query, flags, Keyword.get(flags, :tier))
  end

  defp tiered_command(msg, spec, _query, _flags, :query) do
    tier = Config.get(spec.tier_key) || spec.default_tier
    provider = Config.get(spec.provider_key) || "auto"

    Gateway.send_message("#{spec.report_label}: tier=#{tier}, provider=#{provider}",
      gateway: msg.gateway
    )
  end

  defp tiered_command(msg, _spec, "", _flags, tier) when not is_nil(tier),
    do: defaults_elsewhere(msg)

  defp tiered_command(msg, spec, "", _flags, _tier) do
    Gateway.send_message(spec.usage, gateway: msg.gateway)
  end

  defp tiered_command(msg, spec, query, flags, _tier) do
    tier = CommandParser.resolve_tier(flags, spec.tier_key, spec.default_tier)
    provider = CommandParser.resolve_provider(flags, spec.provider_key)

    Gateway.send_message("#{spec.label} (tier: #{tier}, provider: #{provider})",
      gateway: msg.gateway
    )

    spec.skill
    |> run_skill(%{input: query, llm_tier: to_string(tier), llm_provider: provider}, msg)
    |> answer(msg, "", "#{spec.label} failed")
  end

  defp browse_config([url, question]), do: %{"url" => url, "question" => question}
  defp browse_config([url]), do: %{"url" => url}

  # A review takes minutes, so it runs beside the chat; its report, or why it
  # failed, is the reply.
  defp review(config, msg) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      "github_security_review"
      |> run_skill(%{config: config}, msg)
      |> answer(msg, "", "⚠️ GitHub security review failed")
    end)
  end

  # A chat command runs its skill as every skill runs: through the control
  # plane (:run_skill from the gateway, audited) and SafeExecutor, which
  # refuses a skill that is not available. The chat's own wording — a heading,
  # "… failed:" — is added here, never inside the skill.
  defp run_skill(skill, args, msg) do
    ControlPlane.perform(
      :run_skill,
      %{caller: __MODULE__, skill: skill, args: args},
      Context.gateway(msg.chat_id)
    )
  end

  defp answer({:ok, text, _branch}, msg, heading, _failed) when is_binary(text),
    do: Gateway.send_message(heading <> text, gateway: msg.gateway)

  defp answer({:ok, text}, msg, heading, _failed) when is_binary(text),
    do: Gateway.send_message(heading <> text, gateway: msg.gateway)

  defp answer({:ok, _nothing, branch}, msg, _heading, _failed),
    do: Gateway.send_message("Nothing to report (#{branch}).", gateway: msg.gateway)

  defp answer({:error, {:unavailable, reason}}, msg, _heading, _failed),
    do: Gateway.send_message(reason, gateway: msg.gateway)

  defp answer({:error, reason}, msg, _heading, failed) do
    Gateway.send_message("#{failed}: #{AlexClaw.FailureText.describe(reason)}",
      gateway: msg.gateway
    )
  end

  # A chat operates AlexClaw; it never authors it: a command's default tier
  # and provider are settings, changed in the admin UI.
  defp defaults_elsewhere(msg) do
    Gateway.send_message(
      "Default tiers and providers are set in the admin UI (Config page), not over a chat.",
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
    :run_workflow
    |> ControlPlane.perform(%{workflow_id: workflow.id}, Context.gateway(msg.chat_id))
    |> started(workflow, msg)
  end

  defp started({:ok, _started}, workflow, msg),
    do: Gateway.send_message("Workflow '#{workflow.name}' started.", gateway: msg.gateway)

  defp started({:error, :workflow_disabled}, workflow, msg),
    do: Gateway.send_message("Workflow '#{workflow.name}' is disabled.", gateway: msg.gateway)

  defp started({:error, reason}, workflow, msg) do
    Gateway.send_message("Workflow '#{workflow.name}' was not started: #{inspect(reason)}",
      gateway: msg.gateway
    )
  end
end
