defmodule AlexClaw.Workflows.SkillRegistry do
  @moduledoc """
  Manages skill registration via GenServer + ETS.
  Core skills are loaded at init. Dynamic skills are compiled from .ex files
  and persisted in the database.
  """
  use GenServer
  require Logger

  alias AlexClaw.Gateway.Router
  alias AlexClaw.Repo
  alias AlexClaw.Skills.{DynamicSkill, SkillAPI}

  @ets_table :skill_registry
  @dynamic_namespace "AlexClaw.Skills.Dynamic."
  @pubsub_topic "skills:registry"

  # Known external call indicators for AST-based detection of dynamic skills.
  # NOTE (v1): This scan is single-module only. Indirect calls through helper
  # modules that wrap these functions won't be caught. Future: integrate Giulia's
  # coupling graph for transitive call analysis at load time.
  @external_indicators [
    {Req, :get},
    {Req, :post},
    {Req, :put},
    {Req, :delete},
    {Req, :request},
    {HTTPoison, :get},
    {HTTPoison, :post},
    {HTTPoison, :request},
    {Finch, :request},
    {Finch, :build},
    {Tesla, :get},
    {Tesla, :post},
    {Tesla, :request},
    {:gen_tcp, :connect},
    {:gen_udp, :open},
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
    "db_backup" => AlexClaw.Skills.DbBackup,
    "web_fetch" => AlexClaw.Skills.WebFetch,
    "web_search_fetch" => AlexClaw.Skills.WebSearchFetch,
    "rss_fetch" => AlexClaw.Skills.RssFetch,
    "llm_score" => AlexClaw.Skills.LlmScore
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
  @spec list_all_with_type() :: [
          {String.t(), module(), :core | :dynamic, :all | [atom()], [atom()], boolean()}
        ]
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

  @doc "Get UI metadata for a skill by name. Used by the step editor to determine which fields to show."
  @spec get_skill_meta(String.t()) :: map()
  def get_skill_meta(name) do
    case :ets.lookup(@ets_table, name) do
      [{_, module, _, _, _, _}] -> build_skill_meta(module)
      [] -> default_skill_meta()
    end
  end

  defp build_skill_meta(module) do
    Code.ensure_loaded(module)

    %{
      step_fields:
        extract_callback(module, :step_fields, [:llm_tier, :llm_model, :prompt_template, :config]),
      config_hint: extract_callback(module, :config_hint, ""),
      config_scaffold: extract_callback(module, :config_scaffold, %{}),
      config_presets: extract_callback(module, :config_presets, %{}),
      prompt_presets: extract_callback(module, :prompt_presets, %{}),
      config_help: extract_callback(module, :config_help, "Skill-specific parameters as JSON."),
      prompt_help:
        extract_callback(
          module,
          :prompt_help,
          "Template sent to the LLM. Use {input} for previous step output."
        )
    }
  end

  defp default_skill_meta do
    %{
      step_fields: [:llm_tier, :llm_model, :prompt_template, :config],
      config_hint: "",
      config_scaffold: %{},
      config_presets: %{},
      prompt_presets: %{},
      config_help: "Skill-specific parameters as JSON.",
      prompt_help: "Template sent to the LLM. Use {input} for previous step output."
    }
  end

  defp extract_callback(module, callback, default) do
    if function_exported?(module, callback, 0) do
      apply(module, callback, [])
    else
      default
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
    skills = Repo.all(from(d in DynamicSkill, where: d.enabled == true))

    for skill <- skills, do: load_persisted_skill(skill, Path.join(skills_dir(), skill.file_path))
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

      Logger.info(
        "Dynamic skill loaded: #{skill_name} with permissions: #{inspect(permissions)}, routes: #{inspect(routes)}, external: #{external}"
      )

      {:ok,
       %{
         name: skill_name,
         module: module,
         permissions: permissions,
         routes: routes,
         external: external
       }}
    end
  end

  defp load_persisted_skill(skill, full_path) do
    verify_and_load(File.exists?(full_path), skill, full_path)
  end

  defp verify_and_load(false, skill, _full_path) do
    Logger.warning("Dynamic skill file missing: #{skill.file_path}")
  end

  defp verify_and_load(true, skill, full_path) do
    checksum_matched(file_checksum(full_path) == skill.checksum, skill, full_path)
  end

  # The file changed since it was registered, so its recorded permissions can no
  # longer be trusted — refuse to load it rather than run unreviewed code.
  defp checksum_matched(false, skill, _full_path) do
    Logger.warning(
      "Checksum mismatch for skill #{skill.name} — file changed since last load. Skipping."
    )

    notify_checksum_mismatch(skill.name)
  end

  defp checksum_matched(true, skill, full_path) do
    full_path
    |> compile_and_validate()
    |> register_compiled(skill)
  end

  defp register_compiled({:error, reason}, skill) do
    Logger.warning("Failed to load dynamic skill #{skill.name}: #{inspect(reason)}")
    notify_load_failure(skill.name, reason)
  end

  defp register_compiled({:ok, module, permissions}, skill) do
    :ets.insert(
      @ets_table,
      {skill.name, module, :dynamic, permissions, extract_routes(module),
       extract_external(module)}
    )

    Logger.info("Dynamic skill loaded: #{skill.name}")
  end

  defp check_version_bump(module, skill_name) do
    case :ets.lookup(@ets_table, skill_name) do
      [{^skill_name, old_module, :dynamic, _, _, _}] ->
        compare_versions(version_of(old_module), version_of(module))

      _ ->
        :ok
    end
  end

  defp version_of(module) do
    if function_exported?(module, :version, 0), do: module.version(), else: nil
  end

  # Neither side declares a version, so a bump cannot be detected at all.
  defp compare_versions(nil, nil) do
    {:error, {:same_version, nil, "Add a version/0 callback to track skill versions"}}
  end

  defp compare_versions(same, same) do
    {:error,
     {:same_version, same, "Bump the version before reloading. Use /skill reload to force."}}
  end

  defp compare_versions(_old_version, _new_version), do: :ok

  defp do_unload_skill(name) do
    case :ets.lookup(@ets_table, name) do
      [{^name, _module, :core, _, _, _}] ->
        {:error, :cannot_unload_core}

      [{^name, module, :dynamic, _, _, _}] ->
        :ets.delete(@ets_table, name)

        import Ecto.Query
        Repo.delete_all(from(d in DynamicSkill, where: d.name == ^name))

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

    case Repo.one(from(d in DynamicSkill, where: d.name == ^name)) do
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

          {:ok,
           %{
             name: name,
             module: module,
             permissions: permissions,
             routes: routes,
             external: external
           }}
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

  @doc """
  Validate a skill filename before it is written into the skills directory.

  `validate_path/1` guards traversal at load time, but a file has to be written
  before it can be loaded — anything accepting a client-supplied name must call
  this first.
  """
  @spec validate_skill_filename(String.t()) :: :ok | {:error, :invalid_filename}
  def validate_skill_filename(file_name) do
    cond do
      String.contains?(file_name, "..") -> {:error, :invalid_filename}
      String.contains?(file_name, "/") -> {:error, :invalid_filename}
      String.contains?(file_name, "\\") -> {:error, :invalid_filename}
      not String.ends_with?(file_name, ".ex") -> {:error, :invalid_filename}
      true -> :ok
    end
  end

  defp validate_path(full_path) do
    dir = skills_dir()
    normalized = Path.expand(full_path)

    if String.starts_with?(normalized, Path.expand(dir)) do
      if File.exists?(normalized), do: :ok, else: {:error, :file_not_found}
    else
      {:error, :path_traversal}
    end
  end

  # The file is vetted as a syntax tree before anything is compiled. Code.compile_file/1
  # defines every module in the file and runs its body, so a file could quietly replace
  # AlexClaw.Auth.PolicyEngine alongside a well-behaved skill, or act at compile time.
  defp compile_and_validate(full_path) do
    with {:ok, source} <- File.read(full_path),
         {:ok, ast} <- parse_source(source),
         {:ok, expected} <- single_dynamic_module(ast),
         :ok <- validate_module_body(ast),
         :ok <- validate_compile_time_deps(ast) do
      compile_vetted(ast, full_path, expected)
    end
  end

  defp parse_source(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, {_meta, message, token}} -> {:error, {:compilation_error, "#{message}#{token}"}}
    end
  end

  # Exactly one top-level module, in the dynamic namespace. Anything else is refused
  # before it can be defined in the VM.
  defp single_dynamic_module(ast) do
    case top_level_modules(ast) do
      [{:ok, module}] -> {:ok, module}
      [] -> {:error, :no_module_defined}
      [{:error, name}] -> {:error, {:invalid_namespace, name}}
      modules -> {:error, {:multiple_modules, Enum.map(modules, &module_name/1)}}
    end
  end

  defp top_level_modules({:defmodule, _meta, [{:__aliases__, _, parts} | _]}),
    do: [classify_module(parts)]

  defp top_level_modules({:__block__, _meta, statements}),
    do: Enum.flat_map(statements, &top_level_modules/1)

  defp top_level_modules(_ast), do: []

  defp classify_module(parts) do
    name = Enum.map_join(parts, ".", &Atom.to_string/1)

    if String.starts_with?(name <> ".", @dynamic_namespace) do
      {:ok, Module.concat(parts)}
    else
      {:error, name}
    end
  end

  defp module_name({:ok, module}), do: String.replace_leading(to_string(module), "Elixir.", "")
  defp module_name({:error, name}), do: name

  defp compile_vetted(ast, full_path, expected) do
    case Code.compile_quoted(ast, full_path) do
      [{^expected, _bytecode}] -> validate_compiled(expected, full_path)
      compiled -> purge_unexpected(compiled)
    end
  rescue
    e ->
      {:error, {:compilation_error, Exception.message(e)}}
  end

  # Belt and braces: if compilation still yields anything other than the single
  # module we approved, none of it stays resident.
  defp purge_unexpected(compiled) do
    for {module, _bytecode} <- compiled do
      :code.purge(module)
      :code.delete(module)
    end

    {:error, {:multiple_modules, Enum.map(compiled, fn {module, _} -> inspect(module) end)}}
  end

  # Compiling a module runs its body, so the body is restricted to declarations.
  # This stops code executing at load time; it says nothing about what run/1 does
  # once the skill is invoked.
  @rejected_attributes [:on_load, :after_compile, :before_compile, :on_definition, :compile]
  @allowed_attributes [:impl, :moduledoc, :doc, :spec, :behaviour, :type, :typep, :opaque]
  @allowed_sigils [:sigil_w, :sigil_W, :sigil_s, :sigil_S, :sigil_r, :sigil_R]

  defp validate_module_body({:defmodule, _meta, [_alias, [do: body]]}),
    do: validate_statements(body_statements(body))

  defp validate_module_body({:__block__, _meta, statements}),
    do: Enum.find_value(statements, :ok, &reject_or_nil(validate_module_body(&1)))

  defp validate_module_body(_ast), do: :ok

  defp body_statements({:__block__, _meta, statements}), do: statements
  defp body_statements(statement), do: [statement]

  defp reject_or_nil(:ok), do: nil
  defp reject_or_nil(error), do: error

  defp validate_statements(statements) do
    Enum.find_value(statements, :ok, &reject_or_nil(validate_statement(&1)))
  end

  defp validate_statement({:@, _meta, [{name, _, _}]}) when name in @rejected_attributes,
    do: {:error, {:forbidden_construct, "@#{name}"}}

  defp validate_statement({:@, _meta, [{name, _, args}]}), do: validate_attribute(name, args)

  defp validate_statement({:use, _meta, _args}), do: {:error, {:forbidden_construct, "use"}}

  # alias is inert. import and require are allowed here but their target is checked
  # against the allowlist by validate_compile_time_deps/1, over the whole file.
  defp validate_statement({directive, _meta, _args})
       when directive in [:alias, :require, :import],
       do: :ok

  # A function definition is allowed; its body runs only when the function is called.
  defp validate_statement({call, _meta, _args}) when call in [:def, :defp], do: :ok

  # Anything else in a module body executes at compile time. A remote call arrives as
  # {{:., _, [alias, name]}, _, _}, so it is named rather than reported as a tuple.
  defp validate_statement({{:., _meta, [_target, name]}, _call_meta, _args}),
    do: {:error, {:forbidden_construct, "call to #{name}/? in the module body"}}

  defp validate_statement({call, _meta, _args}) when is_atom(call),
    do: {:error, {:forbidden_construct, to_string(call)}}

  defp validate_statement(statement),
    do: {:error, {:forbidden_construct, "expression in the module body: #{summarise(statement)}"}}

  defp summarise(statement) do
    statement |> Macro.to_string() |> String.slice(0, 60)
  end

  # import and require both bring a module's macros into scope, and a macro call
  # expands at compile time wherever it appears — including inside a function body.
  # So the target is checked across the whole file, not only the module body.
  @allowed_compile_time_modules [Logger, AlexClaw.Skills.Helpers, SweetXml]

  defp validate_compile_time_deps(ast) do
    {_ast, errors} = Macro.prewalk(ast, [], &collect_dep_error/2)

    case Enum.reverse(errors) do
      [] -> :ok
      [error | _rest] -> {:error, error}
    end
  end

  defp collect_dep_error({:use, _meta, _args} = node, errors),
    do: {node, [{:forbidden_construct, "use"} | errors]}

  defp collect_dep_error({directive, _meta, args} = node, errors)
       when directive in [:import, :require] and is_list(args) do
    {node, dep_error(directive, dependency_module(args), errors)}
  end

  defp collect_dep_error(node, errors), do: {node, errors}

  defp dep_error(_directive, module, errors) when module in @allowed_compile_time_modules,
    do: errors

  defp dep_error(directive, nil, errors),
    do: [{:forbidden_construct, "#{directive} of an unresolvable module"} | errors]

  defp dep_error(directive, module, errors),
    do: [{:forbidden_construct, "#{directive} #{inspect(module)}"} | errors]

  # Anything that does not resolve to a plain alias — a multi-alias brace form, or a
  # module built at runtime — is refused rather than guessed at.
  defp dependency_module([{:__aliases__, _meta, parts} | _rest]) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  defp dependency_module(_args), do: nil

  defp validate_attribute(name, args) when name in @allowed_attributes do
    if unquote_free?(args), do: :ok, else: {:error, {:forbidden_construct, "unquote in @#{name}"}}
  end

  defp validate_attribute(name, [value]) do
    if literal_attribute?(value) do
      :ok
    else
      {:error, {:forbidden_construct, "@#{name} with a computed value"}}
    end
  end

  defp validate_attribute(name, _args), do: {:error, {:forbidden_construct, "@#{name}"}}

  # A module attribute may hold data, never a computation. Sigils are allowed
  # because ~w/~s/~r are how skills declare lists, strings and patterns.
  defp literal_attribute?({sigil, _meta, _args} = value) when sigil in @allowed_sigils,
    do: unquote_free?(value)

  defp literal_attribute?(value) do
    Macro.quoted_literal?(value) and unquote_free?(value)
  end

  defp unquote_free?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {:unquote, _meta, _args} = node, _acc -> {node, true}
        {:unquote_splicing, _meta, _args} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    not found
  end

  defp validate_compiled(module, full_path) do
    module_str = String.replace_leading(to_string(module), "Elixir.", "")

    cond do
      not String.starts_with?(module_str, @dynamic_namespace) ->
        reject_module(module, {:invalid_namespace, module_str})

      not function_exported?(module, :run, 1) ->
        reject_module(module, :missing_run_callback)

      true ->
        validate_contract(module, full_path, extract_permissions(module))
    end
  end

  # A module that fails validation must not stay resident in the VM.
  defp reject_module(module, reason) do
    :code.purge(module)
    :code.delete(module)
    {:error, reason}
  end

  defp validate_contract(module, full_path, permissions) do
    with :ok <- validate_permissions(permissions),
         :ok <- validate_external_declaration(module, full_path) do
      {:ok, module, permissions}
    end
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
    known = SkillAPI.known_permissions()
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

    case Repo.one(from(d in DynamicSkill, where: d.name == ^name)) do
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
      Router.broadcast(
        "Warning: Dynamic skill '#{skill_name}' file changed since last load. " <>
          "Use /skill reload #{skill_name} to update, or /skill unload #{skill_name} to remove."
      )
    end)
  end

  # A skill that loaded before an upgrade can be refused by a stricter gate
  # afterwards. Without this it would simply be absent, with only a log line.
  defp notify_load_failure(skill_name, reason) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      Router.broadcast(
        "Warning: Dynamic skill '#{skill_name}' did not load: #{inspect(reason)}. " <>
          "It is registered but inactive. Fix the file and /skill reload #{skill_name}, " <>
          "or /skill unload #{skill_name} to remove it."
      )
    end)
  end
end
