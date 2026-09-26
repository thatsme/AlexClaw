defmodule AlexClaw.Skills.SkillAPI do
  @moduledoc """
  Unified API for all skills — core and dynamic.

  Core skills have `:all` permissions and pass every check.
  Dynamic skills declare `@permissions` and are enforced at runtime.

  This is the only module dynamic skills should call for side effects.
  Core skills can also use it for consistency.
  """
  require Logger

  alias AlexClaw.Auth.{AuditLog, AuthContext, PolicyEngine, SafeExecutor}
  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Gateway.Router
  alias AlexClaw.Net.HostGuard
  alias AlexClaw.Workflows.SkillRegistry

  # A skill operates AlexClaw; it never authors it. Nothing here writes a
  # skill, loads one, or creates, changes or starts a workflow — no permission
  # can bring that back (0.4.0 S5b).
  @known_permissions ~w(llm telegram_send gateway_send memory_read memory_write knowledge_read knowledge_write web_read config_read resources_read skill_invoke workflow_read)a

  # parallel_map/4: a skill gets concurrency, bounded, instead of Task directly.
  @default_concurrency 4
  @max_concurrency 8
  @element_timeout 30_000

  # What a SkillAPI call made from a parallel_map/4 element is authorised by.
  @auth_keys [:auth_token, :auth_chain_depth, :auth_workflow_run_id, :auth_skill]

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

  @doc "Complete a prompt built to fit the chosen provider's context window. See `AlexClaw.LLM.complete_fitted/2`."
  @spec llm_complete_fitted(
          skill_mod(),
          (non_neg_integer() | :unlimited -> {:ok, String.t()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, String.t()} | {:error, term()}
  def llm_complete_fitted(skill_module, build, opts \\ []) do
    with :ok <- check_permission(skill_module, :llm) do
      AlexClaw.LLM.complete_fitted(build, opts)
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
      Router.send_message(message, opts)
      :ok
    end
  end

  @doc "Send an HTML message via the gateway."
  @spec send_html(skill_mod(), String.t(), keyword()) :: :ok | {:error, :permission_denied}
  def send_html(skill_module, message, opts \\ []) do
    with :ok <- check_gateway_permission(skill_module) do
      Router.send_html(message, opts)
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
  @spec send_telegram_html(skill_mod(), String.t(), keyword()) ::
          :ok | {:error, :permission_denied}
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
  @spec memory_search(skill_mod(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :permission_denied}
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
  @spec memory_store(skill_mod(), atom() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def memory_store(skill_module, kind, content, opts \\ []) do
    with :ok <- check_permission(skill_module, :memory_write) do
      AlexClaw.Memory.store(kind, content, opts)
    end
  end

  # --- Knowledge ---

  @doc "Search knowledge base by semantic similarity. Opts: :limit, :kind"
  @spec knowledge_search(skill_mod(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :permission_denied}
  def knowledge_search(skill_module, query, opts \\ []) do
    with :ok <- check_permission(skill_module, :knowledge_read) do
      {:ok, AlexClaw.Knowledge.search(query, opts)}
    end
  end

  @doc "Check if a source URL already exists in knowledge base."
  @spec knowledge_exists?(skill_mod(), String.t()) ::
          {:ok, boolean()} | {:error, :permission_denied}
  def knowledge_exists?(skill_module, source_url) do
    with :ok <- check_permission(skill_module, :knowledge_read) do
      {:ok, AlexClaw.Knowledge.exists?(source_url)}
    end
  end

  @doc "Store a knowledge entry. Opts: :source, :metadata, :expires_at"
  @spec knowledge_store(skill_mod(), atom() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def knowledge_store(skill_module, kind, content, opts \\ []) do
    with :ok <- check_permission(skill_module, :knowledge_write) do
      AlexClaw.Knowledge.store(kind, content, opts)
    end
  end

  @doc """
  Delete knowledge entries of a kind whose source starts with a prefix.

  Both `:kind` and `:source_prefix` are required, so a skill cannot express an
  unscoped delete. This is the only route a skill has to removing knowledge —
  reaching for Repo directly bypasses the permission check.
  """
  @spec knowledge_delete(skill_mod(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def knowledge_delete(skill_module, opts) do
    with :ok <- check_permission(skill_module, :knowledge_write) do
      AlexClaw.Knowledge.delete_by_source_prefix(
        Keyword.get(opts, :kind),
        Keyword.get(opts, :source_prefix)
      )
    end
  end

  # --- HTTP ---

  @typedoc """
  Why a skill's HTTP request was refused or failed: no `:web_read` permission,
  an option outside the allow-list, a host that is internal or does not resolve
  (`AlexClaw.Net.HostGuard`), a URL that is not http(s), or Req's own error.
  """
  @type http_error ::
          :permission_denied
          | :option_not_allowed
          | :blocked_host
          | :invalid_url
          | Exception.t()

  @default_user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

  # Options that shape the request. Anything else — adapter, plug, finch,
  # connect_options, unix_socket, base_url — could replace or reconfigure the
  # transport, and the host guard lives in the transport.
  @http_options [
    :headers,
    :params,
    :json,
    :form,
    :body,
    :receive_timeout,
    :retry,
    :max_retries,
    :retry_delay,
    :redirect,
    :max_redirects
  ]

  @doc """
  HTTP GET. Options: #{inspect(@http_options)}; any other option returns
  `{:error, :option_not_allowed}`. A URL whose host is internal, or does not
  resolve, returns `{:error, :blocked_host}` — on every redirect hop too.
  """
  @spec http_get(skill_mod(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, http_error()}
  def http_get(skill_module, url, opts \\ []), do: http_request(skill_module, :get, url, opts)

  @doc "HTTP POST. Same options and refusals as `http_get/3`."
  @spec http_post(skill_mod(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, http_error()}
  def http_post(skill_module, url, opts \\ []), do: http_request(skill_module, :post, url, opts)

  @doc "HTTP request with explicit method. Same options and refusals as `http_get/3`."
  @spec http_request(skill_mod(), atom(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, http_error()}
  def http_request(skill_module, method, url, opts \\ []) do
    with :ok <- check_permission(skill_module, :web_read),
         :ok <- check_http_options(opts) do
      [method: method, url: url]
      |> Kernel.++(opts)
      |> Req.new()
      |> Req.Request.put_new_header("user-agent", @default_user_agent)
      |> HostGuard.attach()
      |> Req.request()
      |> refusal_as_reason()
    end
  end

  defp check_http_options(opts) do
    if Enum.all?(opts, &match?({name, _} when name in @http_options, &1)),
      do: :ok,
      else: {:error, :option_not_allowed}
  end

  defp refusal_as_reason({:error, %HostGuard.BlockedError{reason: reason}}), do: {:error, reason}
  defp refusal_as_reason(result), do: result

  # --- Config ---

  @doc "Read a config value by key. Returns {:ok, value} or {:error, :permission_denied}."
  @spec config_get(skill_mod(), String.t(), term()) ::
          {:ok, term()} | {:error, :permission_denied}
  def config_get(skill_module, key, default \\ nil) do
    with :ok <- check_permission(skill_module, :config_read) do
      read_setting(AlexClaw.Config.sensitive?(key), key, default)
    end
  end

  # A skill may read configuration, never credentials. Core skills that need a
  # token read Config directly — they are trusted code compiled into the release.
  # An unknown key is refused too: absence is not proof that it is safe.
  defp read_setting(true, _key, _default), do: {:error, :sensitive}
  defp read_setting(false, key, default), do: {:ok, AlexClaw.Config.get(key, default)}

  # --- Resources ---

  @doc "List resources with optional filters. Filters: :type, :enabled, :tags"
  @spec list_resources(skill_mod(), map()) :: {:ok, [map()]} | {:error, :permission_denied}
  def list_resources(skill_module, filters \\ %{}) do
    with :ok <- check_permission(skill_module, :resources_read) do
      {:ok, Enum.map(AlexClaw.Resources.list_resources(filters), &redact_resource/1)}
    end
  end

  @doc "Get a single resource by ID."
  @spec get_resource(skill_mod(), integer()) :: {:ok, map()} | {:error, term()}
  def get_resource(skill_module, id) do
    with :ok <- check_permission(skill_module, :resources_read),
         {:ok, resource} <- AlexClaw.Resources.get_resource(id) do
      {:ok, redact_resource(resource)}
    end
  end

  # Core skills read Resources directly and still see the credentials; a skill
  # reading through here gets AlexClaw.Resources.redacted/1, as MCP does.
  defp redact_resource(%AlexClaw.Resources.Resource{} = resource),
    do: AlexClaw.Resources.redacted(resource)

  defp redact_resource(resource), do: resource

  # --- Cross-skill invocation ---

  @doc """
  Invoke another skill by name, through `AlexClaw.ControlPlane.perform/3`
  (`:run_skill`, audited). Returns the skill's run/1 result. A privileged
  skill is refused.
  """
  @spec run_skill(skill_mod(), String.t(), map()) ::
          {:ok, term()} | {:ok, term(), atom()} | {:error, term()}
  def run_skill(skill_module, skill_name, args) do
    with :ok <- check_permission(skill_module, :skill_invoke) do
      ControlPlane.perform(
        :run_skill,
        %{caller: skill_module, skill: skill_name, args: args},
        Context.skill(inspect(skill_module))
      )
    end
  end

  # --- Skill Outcomes ---

  @doc "Query past execution outcomes for a skill. Opts: :limit, :quality"
  @spec skill_outcomes(skill_mod(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :permission_denied}
  def skill_outcomes(skill_module, skill_name, opts \\ []) do
    with :ok <- check_permission(skill_module, :memory_read) do
      {:ok, AlexClaw.Workflows.list_outcomes(skill_name, opts)}
    end
  end

  @doc "Get aggregate outcome stats for a skill."
  @spec skill_outcome_stats(skill_mod(), String.t()) ::
          {:ok, map()} | {:error, :permission_denied}
  def skill_outcome_stats(skill_module, skill_name) do
    with :ok <- check_permission(skill_module, :memory_read) do
      {:ok, AlexClaw.Workflows.outcome_stats(skill_name)}
    end
  end

  # --- Workflow runs ---

  @doc "Get a workflow run result by run ID."
  @spec get_workflow_result(skill_mod(), integer()) :: {:ok, map()} | {:error, term()}
  def get_workflow_result(skill_module, run_id) do
    with :ok <- check_permission(skill_module, :workflow_read) do
      AlexClaw.Workflows.get_run(run_id)
    end
  end

  # --- Computation ---

  @doc """
  Map `fun` over `enumerable` concurrently, in order, under
  `AlexClaw.TaskSupervisor`. Opts: `:max_concurrency` (default
  #{@default_concurrency}, at most #{@max_concurrency}), `:timeout` per element
  in ms (default #{@element_timeout}). An element that crashes or times out
  becomes `{:error, {:exit, reason}}` in its place; the others are kept.

  Each element runs with the caller's authorisation (token, chain depth,
  workflow run), so a SkillAPI call made inside `fun` is checked as the
  skill's own.
  """
  @spec parallel_map(skill_mod(), Enumerable.t(), (term() -> term()), keyword()) ::
          {:ok, [term()]} | {:error, :too_much_concurrency}
  def parallel_map(_skill_module, enumerable, fun, opts \\ []) when is_function(fun, 1) do
    opts
    |> Keyword.get(:max_concurrency, @default_concurrency)
    |> mapped(enumerable, fun, Keyword.get(opts, :timeout, @element_timeout))
  end

  defp mapped(concurrency, enumerable, fun, timeout)
       when concurrency in 1..@max_concurrency//1 do
    auth = Enum.map(@auth_keys, &{&1, Process.get(&1)})

    results =
      AlexClaw.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(enumerable, &with_auth(auth, fun, &1),
        max_concurrency: concurrency,
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.map(&element/1)

    {:ok, results}
  end

  defp mapped(_concurrency, _enumerable, _fun, _timeout), do: {:error, :too_much_concurrency}

  defp with_auth(auth, fun, value) do
    Enum.each(auth, &restore_auth/1)
    fun.(value)
  end

  defp restore_auth({_key, nil}), do: :ok
  defp restore_auth({key, value}), do: Process.put(key, value)

  defp element({:ok, value}), do: value
  defp element({:exit, reason}), do: {:error, {:exit, reason}}

  @doc """
  A loaded module's documentation, as `Code.fetch_docs/1` returns it
  (`{:docs_v1, ...}`), or `{:error, reason}`.
  """
  @spec module_docs(skill_mod(), module()) :: {:ok, tuple()} | {:error, term()}
  def module_docs(_skill_module, module) when is_atom(module),
    do: docs(Code.fetch_docs(module))

  defp docs({:error, reason}), do: {:error, reason}
  defp docs(docs), do: {:ok, docs}

  # --- Permission check ---

  # The identity is the skill running in this process, as SafeExecutor
  # recorded it — never the module a call names (S8 C1). A call naming another
  # module is refused and audited; code that is not a running skill has no
  # identity, and is refused.
  defp check_permission(skill_module, permission),
    do: checked_as(SafeExecutor.running_skill(), skill_module, permission)

  defp checked_as(nil, _named, _permission), do: {:error, :permission_denied}

  defp checked_as(running, running, permission) do
    permissions = SkillRegistry.get_permissions(running)
    ctx = AuthContext.build(running, permission, permissions)

    case PolicyEngine.evaluate(ctx, permissions) do
      :allow -> :ok
      {:deny, _reason} -> {:error, :permission_denied}
    end
  end

  defp checked_as(running, named, permission) do
    running
    |> AuthContext.build(permission, SkillRegistry.get_permissions(running))
    |> AuditLog.log_deny("named #{inspect(named)} while running as #{inspect(running)}")

    {:error, :permission_denied}
  end
end
