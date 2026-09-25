defmodule AlexClaw.Workflows.SkillRegistry do
  @moduledoc """
  Manages skill registration via GenServer + ETS.
  Core skills are loaded at init. Dynamic skills are compiled from .ex files
  and persisted in the database.
  """
  use GenServer
  require Logger

  alias AlexClaw.BootRetry
  alias AlexClaw.Gateway.Router
  alias AlexClaw.Repo
  alias AlexClaw.Skills.{CallPolicy, DynamicSkill, SkillAPI}

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
    "llm_score" => AlexClaw.Skills.LlmScore,
    "skill_source_indexer" => AlexClaw.Skills.SkillSourceIndexer
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

  @doc """
  The config keys registered skills declare secret, stored encrypted
  (`AlexClaw.Encrypted.StepConfig`). The core skills' keys are known before
  this process starts, so a step read during boot is still decrypted.
  """
  @spec secret_config_keys() :: [String.t()]
  def secret_config_keys do
    (Map.values(@core_skills) ++ registered_modules())
    |> Enum.flat_map(&declared_secrets/1)
    |> Enum.uniq()
  end

  @doc "The config keys `module` declares secret; none if it declares nothing."
  @spec declared_secrets(module()) :: [String.t()]
  def declared_secrets(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :secret_config_keys, 0),
      do: module.secret_config_keys(),
      else: []
  end

  # Whole underscore-separated segments, not substrings: `api_key` and
  # `auth_header` name credentials, `keyword_count` does not.
  @credential_segments ~w(token key apikey password secret credential auth authorization headers)

  @doc """
  Config keys of `module` named like a credential but not declared in
  `secret_config_keys/0` — keys that would be stored in plain text. The config
  keys are those of `config_scaffold/0` and every `config_presets/0` entry.
  """
  @spec undeclared_secrets(module()) :: [String.t()]
  def undeclared_secrets(module) do
    Code.ensure_loaded(module)
    presets = extract_callback(module, :config_presets, %{})
    configs = [extract_callback(module, :config_scaffold, %{}) | Map.values(presets)]

    configs
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.map(&to_string/1)
    |> Enum.filter(&credential_name?/1)
    |> Enum.uniq()
    |> Kernel.--(declared_secrets(module))
    |> Enum.sort()
  end

  @doc "Whether a config key's name, split on underscores, has a credential segment."
  @spec credential_name?(String.t()) :: boolean()
  def credential_name?(name) do
    name
    |> String.downcase()
    |> String.split("_")
    |> Enum.any?(&(&1 in @credential_segments))
  end

  @doc "The core skill modules."
  @spec core_modules() :: [module()]
  def core_modules, do: Map.values(@core_skills)

  defp registered_modules do
    case :ets.whereis(@ets_table) do
      :undefined -> []
      table -> :ets.select(table, [{{:_, :"$1", :_, :_, :_, :_}, [], [:"$1"]}])
    end
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
  @spec load_skill(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_skill(file_path, opts \\ []) do
    provenance = %{
      origin: Keyword.get(opts, :origin, "upload"),
      approval: Keyword.get(opts, :approval, "totp")
    }

    GenServer.call(__MODULE__, {:load_skill, file_path, provenance}, 30_000)
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

  @doc """
  Re-run the boot load of persisted dynamic skills.

  Every dynamic skill, whoever approved it, is judged again against the current
  allowlist, so an allowlist tightened in a release takes effect without waiting
  for a restart. A code approves a skill's permissions, not calls outside the
  allowlist (0.4.0 S6).
  """
  @spec reload_persisted() :: :ok
  def reload_persisted do
    GenServer.call(__MODULE__, :reload_persisted, 30_000)
  end

  @doc """
  Turn a load failure into a sentence a person can act on.

  Every surface that reports a failed load — the Skills page, the Forge page, the
  gateway reply after a 2FA code — formats it through here, so the same refusal
  reads the same way wherever it appears.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:invalid_namespace, module}),
    do: "Module must be under AlexClaw.Skills.Dynamic.*, got #{module}"

  def describe_error(:missing_run_callback), do: "Module must export run/1"

  def describe_error({:undeclared_secrets, keys}),
    do:
      "Config keys named like credentials must be listed in secret_config_keys/0, " <>
        "so they are stored encrypted: #{Enum.join(keys, ", ")}"

  def describe_error({:unknown_permissions, invalid}),
    do: "Unknown permissions: #{inspect(invalid)}"

  def describe_error(:name_conflicts_with_core), do: "Name conflicts with a core skill"

  def describe_error({:compilation_error, message}),
    do: "Compilation error: #{String.slice(to_string(message), 0, 300)}"

  def describe_error(:path_traversal), do: "File must be inside the skills directory"
  def describe_error(:file_not_found), do: "File not found"
  def describe_error(:invalid_filename), do: "Filename must be a plain .ex name"
  def describe_error(:not_found), do: "Skill not found"
  def describe_error(:cannot_unload_core), do: "Core skills cannot be unloaded"

  def describe_error({:same_version, nil, hint}), do: "No version defined. #{hint}"

  def describe_error({:same_version, version, hint}),
    do: "Version #{version} already loaded. #{hint}"

  def describe_error({:forbidden_construct, construct}),
    do: "Not allowed in a dynamic skill: #{construct}"

  def describe_error({:multiple_modules, modules}),
    do: "A skill file must define exactly one module, found: #{Enum.join(modules, ", ")}"

  def describe_error({:would_replace, owner}),
    do: "That name already belongs to #{owner}; generation will not replace it"

  def describe_error({:not_contained, violations}),
    do: "Calls outside the contained set: #{Enum.join(violations, ", ")}"

  def describe_error({:runtime_validation, reason}),
    do: "Compiled, but failed when run: #{describe_error(reason)}"

  def describe_error({:runtime_timeout, message}), do: message
  def describe_error({:runtime_bad_result, message}), do: message
  def describe_error({:runtime_error_returned, message}), do: message
  def describe_error({:runtime_crash, message}), do: "Crashed when run: #{message}"

  def describe_error(reason), do: inspect(reason)

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

    # The dynamic skills come from the database, and this process is child 7 of
    # 25: querying here makes every child after it wait on that query, and a
    # database that is a few seconds behind the app turns a delay into a crash
    # loop. handle_continue/2 runs before any other message, so a caller that
    # goes through this process still sees a complete registry.
    #
    # The core skills stay here on purpose. They are compiled in, need no
    # database, and a lookup for one must never race the boot.
    {:ok, %{table: table, attempts: 0}, {:continue, :load_dynamic_skills}}
  end

  @impl true
  def handle_continue(:load_dynamic_skills, state), do: {:noreply, load_or_retry(state)}

  @impl true
  def handle_info(:load_dynamic_skills, state), do: {:noreply, load_or_retry(state)}

  @impl true
  def handle_call({:load_skill, file_path, provenance}, _from, state) do
    result = do_load_skill(file_path, provenance)
    {:reply, result, state}
  end

  def handle_call(:reload_persisted, _from, state) do
    log_if_failed(load_dynamic_skills_from_db())
    {:reply, :ok, state}
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
    with {:ok, skills} <- enabled_skills() do
      for skill <- skills,
          do: load_persisted_skill(skill, Path.join(skills_dir(), skill.file_path))

      :ok
    end
  end

  # Only the query is guarded, and deliberately so. A skill that fails to load
  # is a problem with that skill, and load_persisted_skill/2 owns it; a failure
  # here is the database, which at boot is a matter of timing.
  #
  # Broad on purpose: an unreachable server raises DBConnection.ConnectionError
  # and a missing table raises Postgrex.Error. The rescue that used to be here
  # named only the second, so a database that was not there yet went straight
  # past it and killed the process.
  defp enabled_skills do
    import Ecto.Query
    {:ok, Repo.all(from(d in DynamicSkill, where: d.enabled == true))}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp load_or_retry(state), do: settle(load_dynamic_skills_from_db(), state)

  defp settle(:ok, state), do: %{state | attempts: 0}

  defp settle({:error, reason}, state) do
    attempts = BootRetry.schedule(:load_dynamic_skills, state.attempts, "Dynamic skills", reason)
    %{state | attempts: attempts}
  end

  defp log_if_failed(:ok), do: :ok

  defp log_if_failed({:error, reason}) do
    Logger.warning("Dynamic skills not reloaded: #{reason}")
  end

  defp do_load_skill(file_path, provenance) do
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
             compute_checksum(source),
             provenance
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

  # A name that has since become a core skill (skill_source_indexer, 0.4.0 S6)
  # stays the core skill's: the persisted one would replace it in the table.
  defp load_persisted_skill(%{name: name} = skill, _full_path)
       when is_map_key(@core_skills, name) do
    Logger.warning(
      "Dynamic skill #{skill.name} not loaded: a core skill has that name now, " <>
        "and runs in its place."
    )
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
     {:same_version, same,
      "Bump the version before loading, or reload it from the Admin UI to force."}}
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
      nil -> {:error, :not_found}
      record -> reload_record(name, record)
    end
  end

  # The old module is purged only once the new file has compiled and validated.
  # Purging first meant a rejected reload left the skill unloaded: a bad edit took
  # a working skill out of service until it was fixed.
  defp reload_record(name, record) do
    full_path = Path.join(skills_dir(), record.file_path)

    with {:ok, source} <- File.read(full_path),
         {:ok, module, permissions} <- compile_and_validate(full_path) do
      purge_previous(name, module)
      persist_reload(name, record, module, permissions, compute_checksum(source))
    end
  end

  # Nothing to purge when the reload produced the same module that is already
  # resident — deleting it would unload the code that was just compiled.
  defp purge_previous(name, new_module) do
    case :ets.lookup(@ets_table, name) do
      [{^name, old_module, :dynamic, _, _, _}] when old_module != new_module ->
        :code.purge(old_module)
        :code.delete(old_module)

      _other ->
        :ok
    end
  end

  defp persist_reload(name, record, module, permissions, checksum) do
    routes = extract_routes(module)
    external = extract_external(module)

    Repo.update!(
      DynamicSkill.changeset(record, %{
        checksum: checksum,
        permissions: Enum.map(permissions, &to_string/1),
        routes: Enum.map(routes, &to_string/1),
        module_name: to_string(module),
        # A reload is TOTP-gated at every call site, so it re-establishes that
        # approval regardless of how the skill originally arrived.
        approval: "totp"
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

  @doc """
  Stage an uploaded skill file without making it loadable.

  The file lands in `<skills_dir>/pending/`, which nothing loads from: dynamic
  skills are loaded from database records, and the loader only ever resolves names
  against `<skills_dir>` itself. The upload therefore cannot replace a live skill
  before the 2FA challenge is answered.
  """
  @spec stage_upload(Path.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_filename}
  def stage_upload(tmp_path, file_name) do
    with :ok <- validate_skill_filename(file_name) do
      File.mkdir_p!(pending_dir())
      sweep_stale_pending()
      File.cp!(tmp_path, Path.join(pending_dir(), file_name))
      {:ok, file_name}
    end
  end

  # An upload whose challenge is never answered would otherwise sit here forever.
  @pending_ttl_seconds 3600

  defp sweep_stale_pending do
    cutoff = System.os_time(:second) - @pending_ttl_seconds

    case File.ls(pending_dir()) do
      {:ok, names} -> Enum.each(names, &discard_if_stale(&1, cutoff))
      {:error, _reason} -> :ok
    end
  end

  defp discard_if_stale(name, cutoff) do
    path = Path.join(pending_dir(), name)

    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} when mtime < cutoff -> File.rm(path)
      _other -> :ok
    end
  end

  @doc """
  Move a staged upload into the live skills directory.

  Returns `:no_pending` when nothing is staged under that name, which is the
  normal case for loading a file that is already in place.
  """
  @spec promote_pending(String.t()) :: :ok | :no_pending | {:error, term()}
  def promote_pending(file_name) do
    with :ok <- validate_skill_filename(file_name) do
      staged = Path.join(pending_dir(), file_name)
      promote_staged(staged, File.exists?(staged), file_name)
    end
  end

  defp promote_staged(_staged, false, _file_name), do: :no_pending

  defp promote_staged(staged, true, file_name) do
    live = Path.join(skills_dir(), file_name)

    case File.rename(staged, live) do
      :ok -> :ok
      {:error, reason} -> {:error, {:promote_failed, reason}}
    end
  end

  @doc "Directory holding uploads awaiting 2FA verification."
  @spec pending_dir() :: Path.t()
  def pending_dir, do: Path.join(skills_dir(), "pending")

  @doc """
  Write generated source into `pending/` without making it loadable.

  Generated code never lands in the live directory. Whether it gets there depends
  on the verdict from `vet_pending/1`.
  """
  @spec write_pending(String.t(), String.t()) :: :ok | {:error, :invalid_filename}
  def write_pending(file_name, source) do
    with :ok <- validate_skill_filename(file_name) do
      File.mkdir_p!(pending_dir())
      File.write!(Path.join(pending_dir(), file_name), source)
      :ok
    end
  end

  @doc """
  Compile a staged file far enough to judge it, then remove it from the VM again.

  Returns the module and permissions it declares, plus two verdicts from
  `CallPolicy`: `contained:` — whether it may load unattended (its calls and its
  permissions) — and `calls:` — whether its calls stay inside the allowlist,
  which every dynamic skill must, whoever approves it. A skill whose calls are
  contained but whose permissions are not can still be approved with a code.
  Compiling is safe here because the AST gate refuses anything that would
  execute at compile time; the module is purged afterwards either way, so
  nothing stays resident on the strength of this check alone.
  """
  @spec vet_pending(String.t()) ::
          {:ok,
           %{
             module: module(),
             permissions: [atom()],
             contained: :ok | {:error, [String.t()]},
             calls: :ok | {:error, [String.t()]}
           }}
          | {:error, term()}
  def vet_pending(file_name) do
    with :ok <- validate_skill_filename(file_name),
         path = Path.join(pending_dir(), file_name),
         {:ok, source} <- read_pending(path),
         {:ok, ast} <- parse_source(source),
         {:ok, module, permissions} <- compile_and_validate(path, :unjudged) do
      purge_module(module)

      {:ok,
       %{
         module: module,
         permissions: permissions,
         contained: unattended_verdict(ast, permissions),
         calls: CallPolicy.contained?(ast)
       }}
    end
  end

  @doc """
  What the person asked to approve a staged file is told: the permissions it
  declares, a sentence for each risky one or risky pairing
  (`CallPolicy.risks/1`), and — since a code does not approve them — any calls
  outside the allowlist.

  Read from the source, never compiled: compiling the file would replace the
  loaded module of the skill it updates.
  """
  @spec describe_pending(String.t()) :: {:ok, String.t()} | {:error, term()}
  def describe_pending(file_name) do
    with :ok <- validate_skill_filename(file_name),
         {:ok, source} <- read_pending(Path.join(pending_dir(), file_name)),
         {:ok, ast} <- parse_source(source) do
      {:ok, approval_text(declared_permissions(ast), CallPolicy.contained?(ast))}
    end
  end

  defp approval_text(permissions, calls) do
    sentences =
      [permissions_sentence(permissions) | risk_sentences(permissions)] ++ calls_sentence(calls)

    Enum.join(sentences, " ")
  end

  defp permissions_sentence(:unknown),
    do: "Permissions: not declared as a plain list; they are read when it loads."

  defp permissions_sentence([]), do: "Permissions: none."
  defp permissions_sentence(permissions), do: "Permissions: #{Enum.join(permissions, ", ")}."

  defp risk_sentences(:unknown), do: []
  defp risk_sentences(permissions), do: CallPolicy.risks(permissions)

  defp calls_sentence(:ok), do: []

  defp calls_sentence({:error, violations}),
    do: [
      "It calls outside the contained set, which a code does not approve, " <>
        "so it will not load: #{Enum.join(violations, ", ")}."
    ]

  # `def permissions, do: [...]` with a literal list of atoms, or :unknown.
  defp declared_permissions(ast) do
    {_ast, found} = Macro.prewalk(ast, :unknown, &permissions_node/2)
    found
  end

  defp permissions_node({:def, _meta, [{:permissions, _fmeta, args}, [do: list]]} = node, _acc)
       when args in [nil, []] and is_list(list),
       do: {node, literal_atoms(Enum.all?(list, &is_atom/1), list)}

  defp permissions_node(node, acc), do: {node, acc}

  defp literal_atoms(true, list), do: list
  defp literal_atoms(false, _list), do: :unknown

  @doc """
  Whether generation may take over the name `skill_name`.

  A generated skill may replace one of its own kind and nothing else. Without this
  a goal that happens to derive an existing name would silently overwrite a skill
  somebody uploaded and approved — with no upload, no 2FA, and the same name still
  resolving.
  """
  @spec generation_may_replace?(String.t()) :: :ok | {:error, {:would_replace, String.t()}}
  def generation_may_replace?(skill_name) do
    import Ecto.Query

    case Repo.one(from(d in DynamicSkill, where: d.name == ^skill_name)) do
      nil -> replaceable_core(skill_name)
      %{origin: "generated", approval: "containment"} -> :ok
      record -> {:error, {:would_replace, describe_owner(record)}}
    end
  end

  defp replaceable_core(skill_name) do
    if Map.has_key?(@core_skills, skill_name) do
      {:error, {:would_replace, "a core skill"}}
    else
      :ok
    end
  end

  defp describe_owner(%{origin: "upload"}), do: "a skill that was uploaded and approved"

  defp describe_owner(%{origin: "generated", approval: approval}),
    do: "a generated skill approved by #{approval}"

  defp describe_owner(record), do: "an existing skill (#{record.origin}/#{record.approval})"

  # Both conditions have to hold for an unattended load, and both are reported
  # together so one retry can address all of it.
  defp unattended_verdict(ast, permissions) do
    case {CallPolicy.contained?(ast), CallPolicy.permitted?(permissions)} do
      {:ok, :ok} -> :ok
      {calls, perms} -> {:error, reasons(calls) ++ reasons(perms)}
    end
  end

  defp reasons(:ok), do: []
  defp reasons({:error, found}), do: found

  defp read_pending(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, {:pending_unreadable, reason}}
    end
  end

  defp purge_module(module) do
    :code.purge(module)
    :code.delete(module)
    :ok
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

  # Every dynamic skill is contained, whoever approved it (0.4.0 S6, THREAT_MODEL
  # P9): a code approves the permissions a skill declares, never calls outside the
  # allowlist. Loading and every boot judge it here, against the current allowlist.
  defp compile_and_validate(full_path), do: compile_and_validate(full_path, :contained)

  # The file is vetted as a syntax tree before anything is compiled. Code.compile_file/1
  # defines every module in the file and runs its body, so a file could quietly replace
  # AlexClaw.Auth.PolicyEngine alongside a well-behaved skill, or act at compile time.
  defp compile_and_validate(full_path, judge) do
    with {:ok, source} <- File.read(full_path),
         {:ok, ast} <- parse_source(source),
         {:ok, expected} <- single_dynamic_module(ast),
         :ok <- validate_file_shape(ast),
         :ok <- validate_compile_time_deps(ast),
         :ok <- judged(judge, ast) do
      compile_vetted(ast, full_path, expected)
    end
  end

  # vet_pending/1 compiles to read the module and reports the verdict itself.
  defp judged(:unjudged, _ast), do: :ok
  defp judged(:contained, ast), do: not_contained(CallPolicy.contained?(ast))

  defp not_contained(:ok), do: :ok
  defp not_contained({:error, violations}), do: {:error, {:not_contained, violations}}

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

  # The whole file must be one defmodule and nothing else. A statement sitting at
  # the top level, before or after the module, executes at compile time just as a
  # module-body statement does.
  defp validate_file_shape({:defmodule, _meta, _args} = ast), do: validate_module_body(ast)

  defp validate_file_shape({:__block__, _meta, statements}),
    do: Enum.find_value(statements, :ok, &reject_or_nil(validate_top_level(&1)))

  defp validate_file_shape(statement), do: top_level_error(statement)

  defp validate_top_level({:defmodule, _meta, _args} = ast), do: validate_module_body(ast)
  defp validate_top_level(statement), do: top_level_error(statement)

  defp top_level_error(statement),
    do: {:error, {:forbidden_construct, "top-level expression: #{summarise(statement)}"}}

  defp validate_module_body({:defmodule, _meta, [_alias, [do: body]]}),
    do: validate_statements(body_statements(body))

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

  # A module that compiles but fails its contract must not stay resident: it would
  # remain callable by name despite never being registered or approved. The
  # namespace and run/1 checks already purge; these did not.
  defp validate_contract(module, full_path, permissions) do
    case validate_permissions(permissions) do
      :ok -> validate_declaration(module, full_path, permissions)
      {:error, reason} -> reject_module(module, reason)
    end
  end

  defp validate_declaration(module, full_path, permissions) do
    case validate_external_declaration(module, full_path) do
      :ok -> validate_secrets(module, permissions)
      {:error, reason} -> reject_module(module, reason)
    end
  end

  defp validate_secrets(module, permissions) do
    case undeclared_secrets(module) do
      [] -> {:ok, module, permissions}
      keys -> reject_module(module, {:undeclared_secrets, keys})
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

  defp persist_skill(name, module_name, file_path, permissions, routes, checksum, provenance) do
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
      enabled: true,
      origin: provenance.origin,
      approval: provenance.approval
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

  # Skills are managed from the Admin UI only; the chat has no skill commands.
  defp notify_checksum_mismatch(skill_name) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      Router.broadcast(
        "Warning: dynamic skill '#{skill_name}' was not loaded: its file changed since it was approved. " <>
          "Reload it (with a code) or unload it from the Skills page of the Admin UI."
      )
    end)
  end

  # A skill that loaded before an upgrade can be refused by a stricter gate
  # afterwards. Without this it would simply be absent, with only a log line.
  defp notify_load_failure(skill_name, reason) do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      Router.broadcast(
        "Warning: Dynamic skill '#{skill_name}' did not load: #{inspect(reason)}. " <>
          "It is registered but inactive. Fix the file and reload it, or unload it, " <>
          "from the Skills page of the Admin UI."
      )
    end)
  end
end
