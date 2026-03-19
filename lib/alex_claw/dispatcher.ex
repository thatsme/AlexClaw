defmodule AlexClaw.Dispatcher do
  @moduledoc """
  Routes incoming messages and scheduled events to the correct skill.
  Pattern matches on message content — no LLM for routing.
  """
  require Logger

  alias AlexClaw.{Config, Message, Gateway, SkillSupervisor}

  @spec dispatch(Message.t()) :: :ok | :ignored | term()
  def dispatch(%Message{text: "/ping" <> _} = msg) do
    Gateway.send_message("pong", chat_id: msg.chat_id)
  end

  def dispatch(%Message{text: "/status" <> _}) do
    uptime = :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)
    memory = :erlang.memory(:total) |> div(1_048_576)

    Gateway.send_message("""
    *AlexClaw* status
    Uptime: #{uptime}s
    Memory: #{memory} MB
    Skills running: #{DynamicSupervisor.count_children(SkillSupervisor).active}
    """)
  end


  def dispatch(%Message{text: "/task add " <> title}) do
    case AlexClaw.Skills.GoogleTasks.run(%{config: %{"action" => "add"}, input: String.trim(title)}) do
      {:ok, result, _branch} -> Gateway.send_message(result)
      {:error, reason} -> Gateway.send_message("Failed to add task: #{inspect(reason)}")
    end
  end

  def dispatch(%Message{text: "/tasklists" <> _}) do
    case AlexClaw.Skills.GoogleTasks.run(%{config: %{"action" => "lists"}}) do
      {:ok, result, _branch} -> Gateway.send_message("*Your Task Lists*\n\n#{result}")
      {:error, reason} -> Gateway.send_message("Failed to fetch task lists: #{inspect(reason)}")
    end
  end

  def dispatch(%Message{text: "/tasks" <> _}) do
    case AlexClaw.Skills.GoogleTasks.run(%{config: %{"action" => "list"}}) do
      {:ok, result, _branch} -> Gateway.send_message("*Your Tasks*\n\n#{result}")
      {:error, reason} -> Gateway.send_message("Failed to fetch tasks: #{inspect(reason)}")
    end
  end

  def dispatch(%Message{text: "/research " <> query}) do
    AlexClaw.Skills.Research.handle(String.trim(query))
  end

  def dispatch(%Message{text: "/search " <> query}) do
    AlexClaw.Skills.WebSearch.handle(String.trim(query))
  end

  def dispatch(%Message{text: "/web " <> rest}) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [url, question] ->
        AlexClaw.Skills.WebBrowse.handle(url, question)

      [url] ->
        AlexClaw.Skills.WebBrowse.handle(url)
    end
  end

  def dispatch(%Message{text: "/skills" <> _}) do
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

    Gateway.send_message("*AlexClaw Skills*\n\n#{text}")
  end

  # --- Dynamic Skill Management ---

  def dispatch(%Message{text: "/skill load " <> file_path}) do
    case AlexClaw.Workflows.SkillRegistry.load_skill(String.trim(file_path)) do
      {:ok, %{name: name, permissions: perms}} ->
        perm_list = Enum.map_join(perms, ", ", &to_string/1)
        Gateway.send_message("Skill *#{name}* loaded. Permissions: [#{perm_list}]")

      {:error, :path_traversal} ->
        Gateway.send_message("Error: file must be inside the skills directory.")

      {:error, :file_not_found} ->
        Gateway.send_message("Error: file not found.")

      {:error, {:invalid_namespace, ns}} ->
        Gateway.send_message("Error: module must be under `AlexClaw.Skills.Dynamic.*`, got `#{ns}`")

      {:error, :missing_run_callback} ->
        Gateway.send_message("Error: module must export `run/1`.")

      {:error, {:unknown_permissions, invalid}} ->
        Gateway.send_message("Error: unknown permissions: #{inspect(invalid)}")

      {:error, :name_conflicts_with_core} ->
        Gateway.send_message("Error: name conflicts with a core skill.")

      {:error, {:compilation_error, msg}} ->
        Gateway.send_message("Compilation error:\n`#{String.slice(msg, 0, 500)}`")

      {:error, reason} ->
        Gateway.send_message("Failed to load skill: #{inspect(reason)}")
    end
  end

  def dispatch(%Message{text: "/skill unload " <> name}) do
    case AlexClaw.Workflows.SkillRegistry.unload_skill(String.trim(name)) do
      :ok -> Gateway.send_message("Skill *#{String.trim(name)}* unloaded.")
      {:error, :cannot_unload_core} -> Gateway.send_message("Cannot unload core skills.")
      {:error, :not_found} -> Gateway.send_message("Skill not found: `#{String.trim(name)}`")
    end
  end

  def dispatch(%Message{text: "/skill reload " <> name}) do
    case AlexClaw.Workflows.SkillRegistry.reload_skill(String.trim(name)) do
      {:ok, %{name: n, permissions: perms}} ->
        perm_list = Enum.map_join(perms, ", ", &to_string/1)
        Gateway.send_message("Skill *#{n}* reloaded. Permissions: [#{perm_list}]")

      {:error, :not_found} ->
        Gateway.send_message("Skill not found: `#{String.trim(name)}`")

      {:error, reason} ->
        Gateway.send_message("Failed to reload: #{inspect(reason)}")
    end
  end

  def dispatch(%Message{text: "/skill create " <> name}) do
    case AlexClaw.Workflows.SkillRegistry.create_skill(String.trim(name)) do
      {:ok, file_name} ->
        Gateway.send_message(
          "Template created: `#{file_name}`\n" <>
          "Edit the file, then load with: `/skill load #{file_name}`"
        )

      {:error, :already_exists} ->
        Gateway.send_message("File already exists for skill `#{String.trim(name)}`.")
    end
  end

  def dispatch(%Message{text: "/skill list" <> _} = msg) do
    dispatch(%{msg | text: "/skills"})
  end

  def dispatch(%Message{text: "/skill" <> _}) do
    Gateway.send_message("""
    *Skill plugin commands*
    /skill load <filename> — compile and register a skill
    /skill unload <name> — remove a dynamic skill
    /skill reload <name> — recompile from stored path
    /skill create <name> — generate template in skills dir
    /skill list — list all skills with type
    """)
  end

  def dispatch(%Message{text: "/workflows" <> _}) do
    workflows = AlexClaw.Workflows.list_workflows()

    if workflows == [] do
      Gateway.send_message("No workflows configured.")
    else
      text =
        workflows
        |> Enum.map_join("\n", fn wf ->
          status = if wf.enabled, do: "enabled", else: "disabled"
          schedule = if wf.schedule && wf.schedule != "", do: " `#{wf.schedule}`", else: ""
          "• *#{wf.name}* (#{status}#{schedule}) — id: #{wf.id}"
        end)

      Gateway.send_message("*AlexClaw Workflows*\n\n#{text}\n\nRun with: `/run <id>`")
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
        case require_2fa(msg, %{type: :run_workflow, workflow_id: workflow.id},
               "Run workflow: *#{workflow.name}*") do
          :challenged -> :ok
          :proceed ->
            Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn -> AlexClaw.Workflows.Executor.run(workflow.id) end)
            Gateway.send_message("Workflow '#{workflow.name}' started.")
        end
      else
        Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn -> AlexClaw.Workflows.Executor.run(workflow.id) end)
        Gateway.send_message("Workflow '#{workflow.name}' started.")
      end
    else
      Gateway.send_message("Workflow not found: `#{input}`\nUse /workflows to see available workflows.")
    end
  end

  def dispatch(%Message{text: "/llm" <> _}) do
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

    Gateway.send_message("*AlexClaw LLM Providers*\n\n#{text}")
  end

  def dispatch(%Message{text: "/github pr " <> rest}) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [repo, pr] ->
        case Integer.parse(pr) do
          {pr_number, ""} ->
            AlexClaw.Skills.GitHubSecurityReview.review_pr(repo, pr_number)
            Gateway.send_message("GitHub security review started for PR ##{pr_number} on #{repo}.")

          _ ->
            Gateway.send_message("Invalid PR number: `#{pr}`\nUsage: /github pr owner/repo <number>")
        end

      [repo] ->
        AlexClaw.Skills.GitHubSecurityReview.review_pr(repo, nil)
        Gateway.send_message("GitHub security review started for latest PR on #{repo}.")
    end
  end

  def dispatch(%Message{text: "/github commit " <> rest}) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [repo, sha] ->
        AlexClaw.Skills.GitHubSecurityReview.review_commit(repo, sha)
        Gateway.send_message("GitHub security review started for commit #{String.slice(sha, 0, 8)} on #{repo}.")

      _ ->
        Gateway.send_message("Usage: /github commit owner/repo <sha>")
    end
  end

  # --- Web Automation ---

  def dispatch(%Message{text: "/record stop " <> session_id}) do
    sid = String.trim(session_id)
    case AlexClaw.Skills.WebAutomation.stop_recording(sid) do
      {:ok, result} ->
        actions = result["actions"] || []
        summary = result["summary"] || %{}
        base_url = summary["base_url"] || "unknown"

        steps = actions |> Enum.map(fn a ->
          %{"action" => a["action_type"], "selector" => a["selector"], "value" => a["value"], "url" => a["url"]}
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
        end)

        config = %{"url" => base_url, "steps" => steps}

        case AlexClaw.Resources.create_resource(%{
          name: "Recording #{sid}",
          type: "automation",
          url: base_url,
          metadata: config
        }) do
          {:ok, resource} ->
            Gateway.send_message(
              "Recording stopped. #{length(actions)} action(s) captured.\n" <>
              "Saved as resource *#{resource.name}* (id: #{resource.id})\n\n" <>
              "Assign this resource to a workflow with the `web_automation` skill to replay it."
            )
          {:error, _changeset} ->
            Gateway.send_message(
              "Recording stopped. #{length(actions)} action(s) captured but failed to save as resource.\n\n" <>
              "`#{Jason.encode!(config, pretty: true) |> String.slice(0, 3000)}`"
            )
        end
      {:error, reason} ->
        Gateway.send_message("Failed to stop recording: #{inspect(reason)}")
    end
  end

  def dispatch(%Message{text: "/record start " <> url}) do
    dispatch(%Message{text: "/record " <> url})
  end

  def dispatch(%Message{text: "/record " <> url}) do
    case AlexClaw.Skills.WebAutomation.record(%{"url" => String.trim(url)}) do
      {:ok, result, _branch} ->
        sid = case Regex.run(~r/Session: `([^`]+)`/, result) do
          [_, id] -> id
          _ -> nil
        end
        stop_hint = if sid, do: "\n\nWhen done, tap: `/record stop #{sid}`", else: ""
        Gateway.send_message(result <> stop_hint)
      {:error, :web_automator_disabled} -> Gateway.send_message("Web automator is disabled. Enable in Admin > Config.")
      {:error, reason} -> Gateway.send_message("Failed to start recording: #{inspect(reason)}")
    end
  end

  def dispatch(%Message{text: "/replay " <> id_str}) do
    case id_str |> String.trim() |> Integer.parse() do
      {id, ""} ->
        case AlexClaw.Repo.get(AlexClaw.Resources.Resource, id) do
          nil ->
            Gateway.send_message("Resource #{id} not found.")

          resource when resource.type != "automation" ->
            Gateway.send_message("Resource #{id} is not an automation (type: #{resource.type})")

          resource ->
            config = resource.metadata || %{}
            config = if resource.url && !config["url"], do: Map.put(config, "url", resource.url), else: config
            Gateway.send_message("Replaying *#{resource.name}*...")

            case AlexClaw.Skills.WebAutomation.play(config, []) do
              {:ok, result, _branch} -> Gateway.send_message(result)
              {:error, :web_automator_disabled} -> Gateway.send_message("Web automator is disabled. Enable in Admin > Config.")
              {:error, reason} -> Gateway.send_message("Replay failed: #{inspect(reason)}")
            end
        end

      _ ->
        Gateway.send_message("Usage: /replay <resource_id>")
    end
  end

  def dispatch(%Message{text: "/automate " <> url}) do
    config = %{"url" => String.trim(url), "steps" => [%{"action" => "scrape"}, %{"action" => "screenshot", "value" => "result"}]}
    case AlexClaw.Skills.WebAutomation.play(config, []) do
      {:ok, result, _branch} -> Gateway.send_message(result)
      {:error, :web_automator_disabled} -> Gateway.send_message("Web automator is disabled. Enable in Admin > Config.")
      {:error, reason} -> Gateway.send_message("Failed: #{inspect(reason)}")
    end
  end

  # --- 2FA Setup ---

  def dispatch(%Message{text: "/setup 2fa" <> _} = msg) do
    case AlexClaw.Auth.TOTP.setup() do
      {:ok, %{secret: secret, qr_png: qr_png}} ->
        secret_b32 = Base.encode32(secret, padding: false)

        # Send QR image for desktop/second device
        send_photo(msg.chat_id, qr_png, "Scan from another device, or use the manual key below.")

        # Send manual key for same-phone setup
        Gateway.send_message(
          "Manual setup key (tap to copy):\n`#{secret_b32}`\n\nIn Google Authenticator: + > Enter setup key\nAccount: AlexClaw\nKey: paste the code above\nType: Time-based\n\nThen confirm with: /confirm 2fa <6-digit code>",
          chat_id: msg.chat_id
        )

    end
  end

  def dispatch(%Message{text: "/confirm 2fa " <> code} = msg) do
    case AlexClaw.Auth.TOTP.confirm_setup(String.trim(code)) do
      :ok ->
        Gateway.send_message("2FA enabled! Sensitive actions will now require a code from your authenticator app.", chat_id: msg.chat_id)

      {:error, :invalid_code} ->
        Gateway.send_message("Invalid code. Try again: /confirm 2fa <code>", chat_id: msg.chat_id)

      {:error, :no_pending_setup} ->
        Gateway.send_message("No pending 2FA setup. Start with /setup 2fa", chat_id: msg.chat_id)
    end
  end

  def dispatch(%Message{text: "/disable 2fa" <> _} = msg) do
    if AlexClaw.Auth.TOTP.enabled?() do
      AlexClaw.Auth.TOTP.disable()
      Gateway.send_message("2FA disabled.", chat_id: msg.chat_id)
    else
      Gateway.send_message("2FA is not enabled.", chat_id: msg.chat_id)
    end
  end

  # --- OAuth ---

  def dispatch(%Message{text: "/connect google" <> _} = msg) do
    case AlexClaw.Google.OAuth.generate_auth_url(msg.chat_id) do
      {:ok, url} ->
        Gateway.send_html(
          "<b>Connect Google Calendar</b>\n\nTap the link below to authorize:\n\n#{url}\n\n<i>This link expires in 10 minutes.</i>",
          chat_id: msg.chat_id
        )

      {:error, :client_id_not_configured} ->
        Gateway.send_message(
          "Google OAuth not configured. Set google.oauth.client_id and google.oauth.client_secret in Admin > Config first.",
          chat_id: msg.chat_id
        )
    end
  end

  def dispatch(%Message{text: "/disconnect google" <> _} = msg) do
    AlexClaw.Google.OAuth.disconnect()
    Gateway.send_message("Google disconnected. Refresh token removed.", chat_id: msg.chat_id)
  end

  def dispatch(%Message{text: "/connect" <> _} = msg) do
    Gateway.send_message(
      "Available services:\n/connect google — Google Calendar",
      chat_id: msg.chat_id
    )
  end

  def dispatch(%Message{text: "/help" <> _}) do
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
    """)
  end

  # 2FA challenge response — intercept 6-digit codes when a challenge is pending
  def dispatch(%Message{text: text} = msg) when is_binary(text) do
    trimmed = String.trim(text)

    if Regex.match?(~r/^\d{6}$/, trimmed) and AlexClaw.Auth.TOTP.pending_challenge?(msg.chat_id) do
      case AlexClaw.Auth.TOTP.resolve_challenge(msg.chat_id, trimmed) do
        {:ok, action} ->
          Gateway.send_message("Code verified. Executing...", chat_id: msg.chat_id)
          execute_2fa_action(action, msg)

        {:error, :invalid_code} ->
          Gateway.send_message("Invalid code. Try again (2 minutes remaining).", chat_id: msg.chat_id)

        {:error, :challenge_expired} ->
          Gateway.send_message("Challenge expired. Please trigger the action again.", chat_id: msg.chat_id)
      end
    else
      # Free text → conversational LLM
      AlexClaw.Skills.Conversational.handle(msg)
    end
  end

  def dispatch(_other), do: :ignored

  # --- 2FA Helpers ---

  defp execute_2fa_action(%{type: :run_workflow, workflow_id: id}, _msg) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn -> AlexClaw.Workflows.Executor.run(id) end)
  end

  defp execute_2fa_action(action, msg) do
    Logger.warning("Unknown 2FA action: #{inspect(action)}")
    Gateway.send_message("Action completed.", chat_id: msg.chat_id)
  end

  @doc """
  Wraps a sensitive action with 2FA challenge if enabled.
  If 2FA is not enabled, executes immediately.
  """
  def require_2fa(msg, action, description) do
    if AlexClaw.Auth.TOTP.enabled?() do
      AlexClaw.Auth.TOTP.create_challenge(msg.chat_id, action)
      Gateway.send_message(
        "This action requires 2FA verification.\n#{description}\n\nEnter your 6-digit authenticator code:",
        chat_id: msg.chat_id
      )
      :challenged
    else
      :proceed
    end
  end

  defp send_photo(chat_id, photo_data, caption) do
    token = AlexClaw.Config.get("telegram.bot_token")

    if token && token != "" do
      url = "https://api.telegram.org/bot#{token}/sendPhoto"

      Req.post(url,
        form_multipart: [
          {"chat_id", to_string(chat_id)},
          {"caption", caption},
          {"photo", {photo_data, filename: "qr.png", content_type: "image/png"}}
        ]
      )
    end
  end
end
