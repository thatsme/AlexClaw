defmodule AlexClaw.Workflows.SkillRegistry do
  @moduledoc """
  Manages skill registration via GenServer + ETS.
  Core skills are loaded at init. Dynamic skills are compiled from .ex files
  and persisted in the database.
  """
  use GenServer
  require Logger

  alias AlexClaw.Skills.DynamicSkill
  alias AlexClaw.Repo

  @ets_table :skill_registry
  @dynamic_namespace "AlexClaw.Skills.Dynamic."
  @pubsub_topic "skills:registry"

  # Known external call indicators for AST-based detection of dynamic skills.
  # NOTE (v1): This scan is single-module only. Indirect calls through helper
  # modules that wrap these functions won't be caught. Future: integrate Giulia's
  # coupling graph for transitive call analysis at load time.
  @external_indicators [
    {Req, :get}, {Req, :post}, {Req, :put}, {Req, :delete}, {Req, :request},
    {HTTPoison, :get}, {HTTPoison, :post}, {HTTPoison, :request},
    {Finch, :request}, {Finch, :build},
    {Tesla, :get}, {Tesla, :post}, {Tesla, :request},
    {:gen_tcp, :connect}, {:gen_udp, :open},
    {:httpc, :request},
    {AlexClaw.Skills.SkillAPI, :http_get},
    {AlexClaw.Skills.SkillAPI, :http_post},
    {AlexClaw.Skills.SkillAPI, :http_request}
  ]

  @core_skills %{
    "rss_collector" => AlexClaw.Skills.RSSCollector,
    "web_search" => AlexClaw.Skills.WebSearch,
    "web_browse" => AlexClaw.Skills.WebBrowse,
    "research" => AlexClaw.Skills.Research,
    "conversational" => AlexClaw.Skills.Conversational,
    "llm_transform" => AlexClaw.Workflows.LLMTransform,
    "telegram_notify" => AlexClaw.Skills.TelegramNotify,
    "discord_notify" => AlexClaw.Skills.DiscordNotify,
    "api_request" => AlexClaw.Skills.ApiRequest,
    "github_security_review" => AlexClaw.Skills.GitHubSecurityReview,
    "google_calendar" => AlexClaw.Skills.GoogleCalendar,
    "google_tasks" => AlexClaw.Skills.GoogleTasks,
    "web_automation" => AlexClaw.Skills.WebAutomation,
    "shell" => AlexClaw.Skills.Shell,
    "coder" => AlexClaw.Skills.Coder,
    "send_to_workflow" => AlexClaw.Skills.SendToWorkflow,
    "receive_from_workflow" => AlexClaw.Skills.ReceiveFromWorkflow,
    "db_backup" => AlexClaw.Skills.DbBackup
  }

  # --- Client API (backward-compatible) ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Resolve a skill name string to its module. Returns {:ok, module} or {:error, :unknown_skill}."
  @spec resolve(String.t()) :: {:ok, module()} | {:error, :unknown_skill}
  def resolve(name) when is_binary(name) do
    case :ets.lookup(@ets_table, name) do
      [{^name, module, _type, _perms, _routes, _ext}] -> {:ok, module}
      [] -> {:error, :unknown_skill}
    end
  end

  @doc "List all registered skill names."
  @spec list_skills() :: [String.t()]
  def list_skills do
    @ets_table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc "List all registered skills as {name, module} pairs."
  @spec list_all() :: [{String.t(), module()}]
  def list_all do
    @ets_table
    |> :ets.tab2list()
    |> Enum.map(fn {name, module, _type, _perms, _routes, _ext} -> {name, module} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "List all skills with type, permissions, routes, and external flag."
  @spec list_all_with_type() :: [{String.t(), module(), :core | :dynamic, :all | [atom()], [atom()], boolean()}]
  def list_all_with_type do
    @ets_table
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Get permissions for a module."
  @spec get_permissions(module()) :: :all | [atom()] | nil
  def get_permissions(module) do
    case :ets.match(@ets_table, {:_, module, :_, :"$1", :_, :_}) do
      [[perms]] -> perms
      _ -> nil
    end
  end

  @doc "Get the type (:core or :dynamic) for a module."
  @spec get_type(module()) :: :core | :dynamic | nil
  def get_type(module) do
    case :ets.match(@ets_table, {:_, module, :"$1", :_, :_, :_}) do
      [[type]] -> type
      _ -> nil
    end
  end

  @doc "Get routes for a skill by name."
  @spec get_routes(String.t()) :: [atom()]
  def get_routes(name) do
    case :ets.lookup(@ets_table, name) do
      [{_, _, _, _, routes, _ext}] -> routes
      [] -> [:on_success, :on_error]
    end
  end

  @doc "Check if a skill is tagged as external (fetches data from outside the system)."
  @spec external?(String.t()) :: boolean()
  def external?(name) when is_binary(name) do
    case :ets.lookup(@ets_table, name) do
      [{_, _, _, _, _, external}] -> external
      [] -> false
    end
  end

  @doc "Load a dynamic skill from a file in the skills directory."
  @spec load_skill(String.t()) :: {:ok, map()} | {:error, term()}
  def load_skill(file_path) do
    GenServer.call(__MODULE__, {:load_skill, file_path}, 30_000)
  end

  @doc "Unload a dynamic skill by name."
  @spec unload_skill(String.t()) :: :ok | {:error, atom()}
  def unload_skill(name) do
    GenServer.call(__MODULE__, {:unload_skill, name})
  end

  @doc "Reload a dynamic skill by name."
  @spec reload_skill(String.t()) :: {:ok, map()} | {:error, term()}
  def reload_skill(name) do
    GenServer.call(__MODULE__, {:reload_skill, name})
  end

  @doc "Create a template skill file in the skills directory."
  @spec create_skill(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def create_skill(name) do
    GenServer.call(__MODULE__, {:create_skill, name})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    # Register core skills
    for {name, module} <- @core_skills do
      routes = extract_routes(module)
      external = extract_external(module)
      :ets.insert(table, {name, module, :core, :all, routes, external})
    end

    # Load dynamic skills from DB
    load_dynamic_skills_from_db()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:load_skill, file_path}, _from, state) do
    result = do_load_skill(file_path)
    {:reply, result, state}
  end

  def handle_call({:unload_skill, name}, _from, state) do
    result = do_unload_skill(name)
    {:reply, result, state}
  end

  def handle_call({:reload_skill, name}, _from, state) do
    result = do_reload_skill(name)
    {:reply, result, state}
  end

  def handle_call({:create_skill, name}, _from, state) do
    result = do_create_skill(name)
    {:reply, result, state}
  end

  # --- Internal ---

  defp skills_dir do
    Application.get_env(:alex_claw, :skills_dir, "/app/skills")
  end

  defp load_dynamic_skills_from_db do
    import Ecto.Query
    skills = Repo.all(from d in DynamicSkill, where: d.enabled == true)

    for skill <- skills do
      full_path = Path.join(skills_dir(), skill.file_path)

      if File.exists?(full_path) do
        current_checksum = file_checksum(full_path)

        if current_checksum == skill.checksum do
          case compile_and_validate(full_path) do
            {:ok, module, permissions} ->
              routes = extract_routes(module)
              external = extract_external(module)
              :ets.insert(@ets_table, {skill.name, module, :dynamic, permissions, routes, external})
              Logger.info("Dynamic skill loaded: #{skill.name}")

            {:error, reason} ->
              Logger.warning("Failed to load dynamic skill #{skill.name}: #{inspect(reason)}")
          end
        else
          Logger.warning(
            "Checksum mismatch for skill #{skill.name} — file changed since last load. Skipping."
          )

          notify_checksum_mismatch(skill.name)
        end
      else
        Logger.warning("Dynamic skill file missing: #{skill.file_path}")
      end
    end
  rescue
    e in Postgrex.Error ->
      Logger.warning("Dynamic skills skipped (DB not ready): #{Exception.message(e)}")
  end

  defp do_load_skill(file_path) do
    full_path = Path.join(skills_dir(), file_path)

    with :ok <- validate_path(full_path),
         {:ok, source} <- File.read(full_path),
         {:ok, module, permissions} <- compile_and_validate(full_path),
         :ok <- check_not_core(skill_name_from_module(module)),
         :ok <- check_version_bump(module, skill_name_from_module(module)),
         {:ok, _record} <-
           persist_skill(
             skill_name_from_module(module),
             to_string(module),
             file_path,
             permissions,
             extract_routes(module),
             compute_checksum(source)
           ) do
      skill_name = skill_name_from_module(module)
      routes = extract_routes(module)
      external = extract_external(module)
      :ets.insert(@ets_table, {skill_name, module, :dynamic, permissions, routes, external})
      broadcast({:skill_registered, skill_name})
      Logger.info("Dynamic skill loaded: #{skill_name} with permissions: #{inspect(permissions)}, routes: #{inspect(routes)}, external: #{external}")
      {:ok, %{name: skill_name, module: module, permissions: permissions, routes: routes, external: external}}
    end
  end

  defp check_version_bump(module, skill_name) do
    case :ets.lookup(@ets_table, skill_name) do
      [{^skill_name, old_module, :dynamic, _, _, _}] ->
        old_version = if function_exported?(old_module, :version, 0), do: old_module.version(), else: nil
        new_version = if function_exported?(module, :version, 0), do: module.version(), else: nil

        cond do
          old_version == nil and new_version == nil ->
            {:error, {:same_version, nil, "Add a version/0 callback to track skill versions"}}

          old_version == new_version ->
            {:error, {:same_version, old_version, "Bump the version before reloading. Use /skill reload to force."}}

          true ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp do_unload_skill(name) do
    case :ets.lookup(@ets_table, name) do
      [{^name, _module, :core, _, _, _}] ->
        {:error, :cannot_unload_core}

      [{^name, module, :dynamic, _, _, _}] ->
        :ets.delete(@ets_table, name)

        import Ecto.Query
        Repo.delete_all(from d in DynamicSkill, where: d.name == ^name)

        :code.purge(module)
        :code.delete(module)

        broadcast({:skill_unregistered, name})
        Logger.info("Dynamic skill unloaded: #{name}")
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  defp do_reload_skill(name) do
    import Ecto.Query

    case Repo.one(from d in DynamicSkill, where: d.name == ^name) do
      nil ->
        {:error, :not_found}

      record ->
        full_path = Path.join(skills_dir(), record.file_path)

        # Purge old module
        case :ets.lookup(@ets_table, name) do
          [{^name, old_module, :dynamic, _, _, _}] ->
            :code.purge(old_module)
            :code.delete(old_module)

          _ ->
            :ok
        end

        with {:ok, source} <- File.read(full_path),
             {:ok, module, permissions} <- compile_and_validate(full_path) do
          checksum = compute_checksum(source)

          routes = extract_routes(module)
          external = extract_external(module)

          Repo.update!(
            DynamicSkill.changeset(record, %{
              checksum: checksum,
              permissions: Enum.map(permissions, &to_string/1),
              routes: Enum.map(routes, &to_string/1),
              module_name: to_string(module)
            })
          )

          :ets.insert(@ets_table, {name, module, :dynamic, permissions, routes, external})
          broadcast({:skill_registered, name})
          Logger.info("Dynamic skill reloaded: #{name}")
          {:ok, %{name: name, module: module, permissions: permissions, routes: routes, external: external}}
        end
    end
  end

  defp do_create_skill(name) do
    dir = skills_dir()
    file_name = "#{name}.ex"
    full_path = Path.join(dir, file_name)

    if File.exists?(full_path) do
      {:error, :already_exists}
    else
      module_name = Macro.camelize(name)

      template = """
      defmodule AlexClaw.Skills.Dynamic.#{module_name} do
        @behaviour AlexClaw.Skill

        alias AlexClaw.Skills.SkillAPI

        @impl true
        def permissions, do: [:llm]

        @impl true
        def description, do: "#{name} skill"

        @impl true
        def run(args) do
          _input = args[:input]
          _config = args[:config] || %{}

          # Use SkillAPI for sandboxed access:
          # SkillAPI.llm_complete(__MODULE__, "prompt")
          # SkillAPI.send_telegram(__MODULE__, "message")
          # SkillAPI.http_get(__MODULE__, "https://...")
          # SkillAPI.config_get(__MODULE__, "key")

          # Return triple tuple for conditional routing:
          # {:ok, result, :branch_name}
          {:ok, "Hello from #{name}!", :on_success}
        end
      end
      """

      File.write!(full_path, template)
      {:ok, file_name}
    end
  end

  # --- Validation helpers ---

  defp validate_path(full_path) do
    dir = skills_dir()
    normalized = Path.expand(full_path)

    if String.starts_with?(normalized, Path.expand(dir)) do
      if File.exists?(normalized), do: :ok, else: {:error, :file_not_found}
    else
      {:error, :path_traversal}
    end
  end

  defp compile_and_validate(full_path) do
    case Code.compile_file(full_path) do
      [{module, _bytecode} | _] ->
        module_str = String.replace_leading(to_string(module), "Elixir.", "")

        cond do
          not String.starts_with?(module_str, @dynamic_namespace) ->
            :code.purge(module)
            :code.delete(module)
            {:error, {:invalid_namespace, module_str}}

          not function_exported?(module, :run, 1) ->
            :code.purge(module)
            :code.delete(module)
            {:error, :missing_run_callback}

          true ->
            permissions = extract_permissions(module)

            case validate_permissions(permissions) do
              :ok ->
                case validate_external_declaration(module, full_path) do
                  :ok -> {:ok, module, permissions}
                  error -> error
                end

              error ->
                error
            end
        end

      [] ->
        {:error, :no_module_defined}
    end
  rescue
    e ->
      {:error, {:compilation_error, Exception.message(e)}}
  end

  defp extract_external(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :external, 0) do
      module.external()
    else
      false
    end
  end

  # Validates that dynamic skills with external HTTP/socket calls also declare external/0 → true.
  # Fail-closed: undeclared external calls = skill doesn't load.
  defp validate_external_declaration(module, source_path) do
    if extract_external(module) do
      # Already declared external/0 → true — no check needed
      :ok
    else
      case detect_external_calls(source_path) do
        [] ->
          :ok

        detected ->
          :code.purge(module)
          :code.delete(module)
          {:error, {:undeclared_external, detected}}
      end
    end
  end

  defp detect_external_calls(source_path) do
    case File.read(source_path) do
      {:ok, source} ->
        case Code.string_to_quoted(source) do
          {:ok, ast} -> find_external_calls(ast)
          {:error, _} -> []
        end

      {:error, _} ->
        []
    end
  end

  defp find_external_calls(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        # Module.function(...) calls — e.g. Req.get(...)
        {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _args} = node, acc ->
          module = Module.concat(mod_parts)

          if {module, func} in @external_indicators do
            {node, [{module, func} | acc]}
          else
            {node, acc}
          end

        # Erlang module calls — e.g. :gen_tcp.connect(...)
        {{:., _, [mod, func]}, _, _args} = node, acc when is_atom(mod) ->
          if {mod, func} in @external_indicators do
            {node, [{mod, func} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found |> Enum.uniq() |> Enum.reverse()
  end

  defp extract_routes(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :routes, 0) do
      module.routes()
    else
      [:on_success, :on_error]
    end
  end

  defp extract_permissions(module) do
    cond do
      function_exported?(module, :permissions, 0) ->
        module.permissions()

      function_exported?(module, :__info__, 1) ->
        module.__info__(:attributes)
        |> Keyword.get_values(:permissions)
        |> List.flatten()

      true ->
        []
    end
  end

  defp validate_permissions(permissions) do
    known = AlexClaw.Skills.SkillAPI.known_permissions()
    invalid = Enum.reject(permissions, &(&1 in known))

    if invalid == [] do
      :ok
    else
      {:error, {:unknown_permissions, invalid}}
    end
  end

  defp check_not_core(name) do
    if Map.has_key?(@core_skills, name) do
      {:error, :name_conflicts_with_core}
    else
      :ok
    end
  end

  defp skill_name_from_module(module) do
    module
    |> to_string()
    |> String.replace_leading("Elixir.", "")
    |> String.replace_leading(@dynamic_namespace, "")
    |> Macro.underscore()
  end

  defp persist_skill(name, module_name, file_path, permissions, routes, checksum) do
    import Ecto.Query
    perm_strings = Enum.map(permissions, &to_string/1)
    route_strings = Enum.map(routes, &to_string/1)

    attrs = %{
      name: name,
      module_name: module_name,
      file_path: file_path,
      permissions: perm_strings,
      routes: route_strings,
      checksum: checksum,
      enabled: true
    }

    case Repo.one(from d in DynamicSkill, where: d.name == ^name) do
      nil -> %DynamicSkill{} |> DynamicSkill.changeset(attrs) |> Repo.insert()
      existing -> existing |> DynamicSkill.changeset(attrs) |> Repo.update()
    end
  end

  defp file_checksum(path) do
    path |> File.read!() |> compute_checksum()
  end

  defp compute_checksum(content) do
    Base.encode16(:crypto.hash(:sha256, content), case: :lower)
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(AlexClaw.PubSub, @pubsub_topic, message)
  end

  defp notify_checksum_mismatch(skill_name) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      AlexClaw.Gateway.Router.broadcast(
        "Warning: Dynamic skill '#{skill_name}' file changed since last load. " <>
          "Use /skill reload #{skill_name} to update, or /skill unload #{skill_name} to remove."
      )
    end)
  end
end
