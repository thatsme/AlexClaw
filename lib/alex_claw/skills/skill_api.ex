defmodule AlexClaw.Skills.SkillAPI do
  @moduledoc """
  Unified API for all skills — core and dynamic.

  Core skills have `:all` permissions and pass every check.
  Dynamic skills declare `@permissions` and are enforced at runtime.

  This is the only module dynamic skills should call for side effects.
  Core skills can also use it for consistency.
  """
  require Logger

  @known_permissions ~w(llm telegram_send gateway_send memory_read memory_write knowledge_read knowledge_write web_read config_read resources_read skill_invoke skill_write skill_manage workflow_manage)a

  @type permission_result :: :ok | {:error, :permission_denied}
  @type skill_mod :: module()

  @spec known_permissions() :: [atom()]
  def known_permissions, do: @known_permissions

  # --- LLM ---

  @doc "Complete a prompt via LLM. Opts: :tier, :provider, :system"
  @spec llm_complete(skill_mod(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def llm_complete(skill_module, prompt, opts \\ []) do
    with :ok <- check_permission(skill_module, :llm) do
      AlexClaw.LLM.complete(prompt, opts)
    end
  end

  @doc "Get the system prompt from Identity, with optional context."
  @spec system_prompt(skill_mod(), map()) :: {:ok, String.t()} | {:error, :permission_denied}
  def system_prompt(skill_module, context \\ %{}) do
    with :ok <- check_permission(skill_module, :llm) do
      {:ok, AlexClaw.Identity.system_prompt(context)}
    end
  end

  # --- Gateway (transport-agnostic) ---

  @doc "Send a Markdown message via the gateway. Routes based on :gateway opt."
  @spec send_message(skill_mod(), String.t(), keyword()) :: :ok | {:error, :permission_denied}
  def send_message(skill_module, message, opts \\ []) do
    with :ok <- check_gateway_permission(skill_module) do
      AlexClaw.Gateway.Router.send_message(message, opts)
      :ok
    end
  end

  @doc "Send an HTML message via the gateway."
  @spec send_html(skill_mod(), String.t(), keyword()) :: :ok | {:error, :permission_denied}
  def send_html(skill_module, message, opts \\ []) do
    with :ok <- check_gateway_permission(skill_module) do
      AlexClaw.Gateway.Router.send_html(message, opts)
      :ok
    end
  end

  # --- Telegram (backward compat aliases) ---

  @doc "Send a Markdown message to Telegram. Alias for send_message/3."
  @spec send_telegram(skill_mod(), String.t(), keyword()) :: :ok | {:error, :permission_denied}
  def send_telegram(skill_module, message, opts \\ []) do
    with :ok <- check_gateway_permission(skill_module) do
      AlexClaw.Gateway.send_message(message, opts)
      :ok
    end
  end

  @doc "Send an HTML message to Telegram. Alias for send_html/3."
  @spec send_telegram_html(skill_mod(), String.t(), keyword()) :: :ok | {:error, :permission_denied}
  def send_telegram_html(skill_module, message, opts \\ []) do
    with :ok <- check_gateway_permission(skill_module) do
      AlexClaw.Gateway.send_html(message, opts)
      :ok
    end
  end

  defp check_gateway_permission(skill_module) do
    # Accept either :telegram_send or :gateway_send
    case check_permission(skill_module, :gateway_send) do
      :ok -> :ok
      {:error, _} -> check_permission(skill_module, :telegram_send)
    end
  end

  # --- Memory ---

  @doc "Search memories by semantic similarity. Opts: :limit, :kind"
  @spec memory_search(skill_mod(), String.t(), keyword()) :: {:ok, [map()]} | {:error, :permission_denied}
  def memory_search(skill_module, query, opts \\ []) do
    with :ok <- check_permission(skill_module, :memory_read) do
      {:ok, AlexClaw.Memory.search(query, opts)}
    end
  end

  @doc "List recent memories. Opts: :limit, :kind"
  @spec memory_recent(skill_mod(), keyword()) :: {:ok, [map()]} | {:error, :permission_denied}
  def memory_recent(skill_module, opts \\ []) do
    with :ok <- check_permission(skill_module, :memory_read) do
      {:ok, AlexClaw.Memory.recent(opts)}
    end
  end

  @doc "Check if content or source URL already exists in memory."
  @spec memory_exists?(skill_mod(), String.t()) :: {:ok, boolean()} | {:error, :permission_denied}
  def memory_exists?(skill_module, content_or_source) do
    with :ok <- check_permission(skill_module, :memory_read) do
      {:ok, AlexClaw.Memory.exists?(content_or_source)}
    end
  end

  @doc "Store a memory entry. Opts: :source, :metadata, :expires_at"
  @spec memory_store(skill_mod(), atom() | String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def memory_store(skill_module, kind, content, opts \\ []) do
    with :ok <- check_permission(skill_module, :memory_write) do
      AlexClaw.Memory.store(kind, content, opts)
    end
  end

  # --- Knowledge ---

  @doc "Search knowledge base by semantic similarity. Opts: :limit, :kind"
  @spec knowledge_search(skill_mod(), String.t(), keyword()) :: {:ok, [map()]} | {:error, :permission_denied}
  def knowledge_search(skill_module, query, opts \\ []) do
    with :ok <- check_permission(skill_module, :knowledge_read) do
      {:ok, AlexClaw.Knowledge.search(query, opts)}
    end
  end

  @doc "Check if a source URL already exists in knowledge base."
  @spec knowledge_exists?(skill_mod(), String.t()) :: {:ok, boolean()} | {:error, :permission_denied}
  def knowledge_exists?(skill_module, source_url) do
    with :ok <- check_permission(skill_module, :knowledge_read) do
      {:ok, AlexClaw.Knowledge.exists?(source_url)}
    end
  end

  @doc "Store a knowledge entry. Opts: :source, :metadata, :expires_at"
  @spec knowledge_store(skill_mod(), atom() | String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def knowledge_store(skill_module, kind, content, opts \\ []) do
    with :ok <- check_permission(skill_module, :knowledge_write) do
      AlexClaw.Knowledge.store(kind, content, opts)
    end
  end

  # --- HTTP ---

  @doc "HTTP GET. All Req options are passed through (headers, receive_timeout, params, etc)."
  @spec http_get(skill_mod(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def http_get(skill_module, url, opts \\ []) do
    with :ok <- check_permission(skill_module, :web_read) do
      Req.get(url, opts)
    end
  end

  @doc "HTTP POST. All Req options are passed through."
  @spec http_post(skill_mod(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def http_post(skill_module, url, opts \\ []) do
    with :ok <- check_permission(skill_module, :web_read) do
      Req.post(url, opts)
    end
  end

  @doc "HTTP request with explicit method. All Req options are passed through."
  @spec http_request(skill_mod(), atom(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def http_request(skill_module, method, url, opts \\ []) do
    with :ok <- check_permission(skill_module, :web_read) do
      Req.request([method: method, url: url] ++ opts)
    end
  end

  # --- Config ---

  @doc "Read a config value by key. Returns {:ok, value} or {:error, :permission_denied}."
  @spec config_get(skill_mod(), String.t(), term()) :: {:ok, term()} | {:error, :permission_denied}
  def config_get(skill_module, key, default \\ nil) do
    with :ok <- check_permission(skill_module, :config_read) do
      {:ok, AlexClaw.Config.get(key, default)}
    end
  end

  # --- Resources ---

  @doc "List resources with optional filters. Filters: :type, :enabled, :tags"
  @spec list_resources(skill_mod(), map()) :: {:ok, [map()]} | {:error, :permission_denied}
  def list_resources(skill_module, filters \\ %{}) do
    with :ok <- check_permission(skill_module, :resources_read) do
      {:ok, AlexClaw.Resources.list_resources(filters)}
    end
  end

  @doc "Get a single resource by ID."
  @spec get_resource(skill_mod(), integer()) :: {:ok, map()} | {:error, term()}
  def get_resource(skill_module, id) do
    with :ok <- check_permission(skill_module, :resources_read) do
      AlexClaw.Resources.get_resource(id)
    end
  end

  # --- Cross-skill invocation ---

  @doc "Invoke another skill by name. Returns the skill's run/1 result."
  @spec run_skill(skill_mod(), String.t(), map()) :: {:ok, term()} | {:ok, term(), atom()} | {:error, term()}
  def run_skill(skill_module, skill_name, args) do
    with :ok <- check_permission(skill_module, :skill_invoke) do
      case AlexClaw.Workflows.SkillRegistry.resolve(skill_name) do
        {:ok, target_module} ->
          depth = Process.get(:auth_chain_depth, 0)
          Process.put(:auth_chain_depth, depth + 1)

          # Attenuate current token to target skill's permissions
          current_token = Process.get(:auth_token)
          target_perms = AlexClaw.Workflows.SkillRegistry.get_permissions(target_module)

          attenuated =
            if current_token && is_list(target_perms) do
              case AlexClaw.Auth.CapabilityToken.attenuate(current_token, target_perms) do
                {:ok, token} -> token
                _ -> current_token
              end
            else
              current_token
            end

          if attenuated, do: Process.put(:auth_token, attenuated)

          try do
            target_module.run(args)
          after
            Process.put(:auth_chain_depth, depth)
            if current_token, do: Process.put(:auth_token, current_token)
          end

        {:error, :unknown_skill} ->
          {:error, {:unknown_skill, skill_name}}
      end
    end
  end

  # --- Skill Outcomes ---

  @doc "Query past execution outcomes for a skill. Opts: :limit, :quality"
  @spec skill_outcomes(skill_mod(), String.t(), keyword()) :: {:ok, [map()]} | {:error, :permission_denied}
  def skill_outcomes(skill_module, skill_name, opts \\ []) do
    with :ok <- check_permission(skill_module, :memory_read) do
      {:ok, AlexClaw.Workflows.list_outcomes(skill_name, opts)}
    end
  end

  @doc "Get aggregate outcome stats for a skill."
  @spec skill_outcome_stats(skill_mod(), String.t()) :: {:ok, map()} | {:error, :permission_denied}
  def skill_outcome_stats(skill_module, skill_name) do
    with :ok <- check_permission(skill_module, :memory_read) do
      {:ok, AlexClaw.Workflows.outcome_stats(skill_name)}
    end
  end

  # --- Skill File I/O ---

  @doc "Write a skill file to the skills directory. Validates filename safety."
  @spec write_skill(skill_mod(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_skill(skill_module, file_name, code_string) do
    with :ok <- check_permission(skill_module, :skill_write),
         :ok <- validate_skill_filename(file_name) do
      dir = Application.get_env(:alex_claw, :skills_dir, "/app/skills")
      File.mkdir_p!(dir)
      File.write(Path.join(dir, file_name), code_string)
    end
  end

  @doc "Read a skill file from the skills directory."
  @spec read_skill(skill_mod(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_skill(skill_module, file_name) do
    with :ok <- check_permission(skill_module, :skill_write),
         :ok <- validate_skill_filename(file_name) do
      dir = Application.get_env(:alex_claw, :skills_dir, "/app/skills")
      File.read(Path.join(dir, file_name))
    end
  end

  defp validate_skill_filename(file_name) do
    cond do
      String.contains?(file_name, "..") -> {:error, :invalid_filename}
      String.contains?(file_name, "/") -> {:error, :invalid_filename}
      String.contains?(file_name, "\\") -> {:error, :invalid_filename}
      not String.ends_with?(file_name, ".ex") -> {:error, :invalid_filename}
      true -> :ok
    end
  end

  # --- Skill Lifecycle ---

  @doc "Load a dynamic skill from a file in the skills directory."
  @spec load_skill(skill_mod(), String.t()) :: {:ok, map()} | {:error, term()}
  def load_skill(skill_module, file_name) do
    with :ok <- check_permission(skill_module, :skill_manage) do
      AlexClaw.Workflows.SkillRegistry.load_skill(file_name)
    end
  end

  @doc "Unload a dynamic skill by name."
  @spec unload_skill(skill_mod(), String.t()) :: :ok | {:error, term()}
  def unload_skill(skill_module, skill_name) do
    with :ok <- check_permission(skill_module, :skill_manage) do
      AlexClaw.Workflows.SkillRegistry.unload_skill(skill_name)
    end
  end

  @doc "Reload a dynamic skill by name."
  @spec reload_skill(skill_mod(), String.t()) :: {:ok, map()} | {:error, term()}
  def reload_skill(skill_module, skill_name) do
    with :ok <- check_permission(skill_module, :skill_manage) do
      AlexClaw.Workflows.SkillRegistry.reload_skill(skill_name)
    end
  end

  # --- Workflow Management ---

  @doc "Create a new workflow."
  @spec create_workflow(skill_mod(), map()) :: {:ok, map()} | {:error, term()}
  def create_workflow(skill_module, attrs) do
    with :ok <- check_permission(skill_module, :workflow_manage) do
      AlexClaw.Workflows.create_workflow(attrs)
    end
  end

  @doc "Add a step to a workflow."
  @spec add_workflow_step(skill_mod(), integer(), map()) :: {:ok, map()} | {:error, term()}
  def add_workflow_step(skill_module, workflow_id, step_attrs) do
    with :ok <- check_permission(skill_module, :workflow_manage) do
      case AlexClaw.Workflows.get_workflow(workflow_id) do
        {:ok, workflow} -> AlexClaw.Workflows.add_step(workflow, step_attrs)
        {:error, _} = err -> err
      end
    end
  end

  @doc "Run a workflow by ID."
  @spec run_workflow(skill_mod(), integer()) :: {:ok, term()} | {:error, term()}
  def run_workflow(skill_module, workflow_id) do
    with :ok <- check_permission(skill_module, :workflow_manage) do
      AlexClaw.Workflows.Executor.run(workflow_id)
    end
  end

  @doc "Get a workflow run result by run ID."
  @spec get_workflow_result(skill_mod(), integer()) :: {:ok, map()} | {:error, term()}
  def get_workflow_result(skill_module, run_id) do
    with :ok <- check_permission(skill_module, :workflow_manage) do
      AlexClaw.Workflows.get_run(run_id)
    end
  end

  # --- Permission check ---

  defp check_permission(skill_module, permission) do
    permissions = AlexClaw.Workflows.SkillRegistry.get_permissions(skill_module)
    ctx = AlexClaw.Auth.AuthContext.build(skill_module, permission, permissions)

    case AlexClaw.Auth.PolicyEngine.evaluate(ctx, permissions) do
      :allow -> :ok
      {:deny, _reason} -> {:error, :permission_denied}
    end
  end
end
