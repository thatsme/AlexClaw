defmodule AlexClaw.Skills.SkillAPI do
  @moduledoc """
  Unified API for all skills — core and dynamic.

  Core skills have `:all` permissions and pass every check.
  Dynamic skills declare `@permissions` and are enforced at runtime.

  This is the only module dynamic skills should call for side effects.
  Core skills can also use it for consistency.
  """
  require Logger

  @known_permissions ~w(llm telegram_send gateway_send memory_read memory_write knowledge_read knowledge_write web_read config_read resources_read skill_invoke)a

  def known_permissions, do: @known_permissions

  # --- LLM ---

  @doc "Complete a prompt via LLM. Opts: :tier, :provider, :system"
  def llm_complete(skill_module, prompt, opts \\ []) do
    with :ok <- check_permission(skill_module, :llm) do
      AlexClaw.LLM.complete(prompt, opts)
    end
  end

  @doc "Get the system prompt from Identity, with optional context."
  def system_prompt(skill_module, context \\ %{}) do
    with :ok <- check_permission(skill_module, :llm) do
      {:ok, AlexClaw.Identity.system_prompt(context)}
    end
  end

  # --- Gateway (transport-agnostic) ---

  @doc "Send a Markdown message via the gateway. Routes based on :gateway opt."
  def send_message(skill_module, message, opts \\ []) do
    with :ok <- check_gateway_permission(skill_module) do
      AlexClaw.Gateway.Router.send_message(message, opts)
      :ok
    end
  end

  @doc "Send an HTML message via the gateway."
  def send_html(skill_module, message, opts \\ []) do
    with :ok <- check_gateway_permission(skill_module) do
      AlexClaw.Gateway.Router.send_html(message, opts)
      :ok
    end
  end

  # --- Telegram (backward compat aliases) ---

  @doc "Send a Markdown message to Telegram. Alias for send_message/3."
  def send_telegram(skill_module, message, opts \\ []) do
    with :ok <- check_gateway_permission(skill_module) do
      AlexClaw.Gateway.send_message(message, opts)
      :ok
    end
  end

  @doc "Send an HTML message to Telegram. Alias for send_html/3."
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
  def memory_search(skill_module, query, opts \\ []) do
    with :ok <- check_permission(skill_module, :memory_read) do
      {:ok, AlexClaw.Memory.search(query, opts)}
    end
  end

  @doc "List recent memories. Opts: :limit, :kind"
  def memory_recent(skill_module, opts \\ []) do
    with :ok <- check_permission(skill_module, :memory_read) do
      {:ok, AlexClaw.Memory.recent(opts)}
    end
  end

  @doc "Check if content or source URL already exists in memory."
  def memory_exists?(skill_module, content_or_source) do
    with :ok <- check_permission(skill_module, :memory_read) do
      {:ok, AlexClaw.Memory.exists?(content_or_source)}
    end
  end

  @doc "Store a memory entry. Opts: :source, :metadata, :expires_at"
  def memory_store(skill_module, kind, content, opts \\ []) do
    with :ok <- check_permission(skill_module, :memory_write) do
      AlexClaw.Memory.store(kind, content, opts)
    end
  end

  # --- Knowledge ---

  @doc "Search knowledge base by semantic similarity. Opts: :limit, :kind"
  def knowledge_search(skill_module, query, opts \\ []) do
    with :ok <- check_permission(skill_module, :knowledge_read) do
      {:ok, AlexClaw.Knowledge.search(query, opts)}
    end
  end

  @doc "Check if a source URL already exists in knowledge base."
  def knowledge_exists?(skill_module, source_url) do
    with :ok <- check_permission(skill_module, :knowledge_read) do
      {:ok, AlexClaw.Knowledge.exists?(source_url)}
    end
  end

  @doc "Store a knowledge entry. Opts: :source, :metadata, :expires_at"
  def knowledge_store(skill_module, kind, content, opts \\ []) do
    with :ok <- check_permission(skill_module, :knowledge_write) do
      AlexClaw.Knowledge.store(kind, content, opts)
    end
  end

  # --- HTTP ---

  @doc "HTTP GET. All Req options are passed through (headers, receive_timeout, params, etc)."
  def http_get(skill_module, url, opts \\ []) do
    with :ok <- check_permission(skill_module, :web_read) do
      Req.get(url, opts)
    end
  end

  @doc "HTTP POST. All Req options are passed through."
  def http_post(skill_module, url, opts \\ []) do
    with :ok <- check_permission(skill_module, :web_read) do
      Req.post(url, opts)
    end
  end

  @doc "HTTP request with explicit method. All Req options are passed through."
  def http_request(skill_module, method, url, opts \\ []) do
    with :ok <- check_permission(skill_module, :web_read) do
      Req.request([method: method, url: url] ++ opts)
    end
  end

  # --- Config ---

  @doc "Read a config value by key. Returns {:ok, value} or {:error, :permission_denied}."
  def config_get(skill_module, key, default \\ nil) do
    with :ok <- check_permission(skill_module, :config_read) do
      {:ok, AlexClaw.Config.get(key, default)}
    end
  end

  # --- Resources ---

  @doc "List resources with optional filters. Filters: :type, :enabled, :tags"
  def list_resources(skill_module, filters \\ %{}) do
    with :ok <- check_permission(skill_module, :resources_read) do
      {:ok, AlexClaw.Resources.list_resources(filters)}
    end
  end

  @doc "Get a single resource by ID."
  def get_resource(skill_module, id) do
    with :ok <- check_permission(skill_module, :resources_read) do
      AlexClaw.Resources.get_resource(id)
    end
  end

  # --- Cross-skill invocation ---

  @doc "Invoke another skill by name. Returns the skill's run/1 result."
  def run_skill(skill_module, skill_name, args) do
    with :ok <- check_permission(skill_module, :skill_invoke) do
      case AlexClaw.Workflows.SkillRegistry.resolve(skill_name) do
        {:ok, target_module} -> target_module.run(args)
        {:error, :unknown_skill} -> {:error, {:unknown_skill, skill_name}}
      end
    end
  end

  # --- Permission check ---

  defp check_permission(skill_module, permission) do
    case AlexClaw.Workflows.SkillRegistry.get_permissions(skill_module) do
      :all ->
        :ok

      permissions when is_list(permissions) ->
        if permission in permissions do
          :ok
        else
          Logger.warning("Permission denied: #{inspect(skill_module)} requires #{permission}")
          {:error, :permission_denied}
        end

      _ ->
        {:error, :permission_denied}
    end
  end
end
