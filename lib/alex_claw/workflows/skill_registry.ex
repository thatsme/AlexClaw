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

  @core_skills %{
    "rss_collector" => AlexClaw.Skills.RSSCollector,
    "web_search" => AlexClaw.Skills.WebSearch,
    "web_browse" => AlexClaw.Skills.WebBrowse,
    "research" => AlexClaw.Skills.Research,
    "conversational" => AlexClaw.Skills.Conversational,
    "llm_transform" => AlexClaw.Workflows.LLMTransform,
    "telegram_notify" => AlexClaw.Skills.TelegramNotify,
    "api_request" => AlexClaw.Skills.ApiRequest,
    "github_security_review" => AlexClaw.Skills.GitHubSecurityReview,
    "google_calendar" => AlexClaw.Skills.GoogleCalendar,
    "google_tasks" => AlexClaw.Skills.GoogleTasks,
    "web_automation" => AlexClaw.Skills.WebAutomation
  }

  # --- Client API (backward-compatible) ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Resolve a skill name string to its module. Returns {:ok, module} or {:error, :unknown_skill}."
  @spec resolve(String.t()) :: {:ok, module()} | {:error, :unknown_skill}
  def resolve(name) when is_binary(name) do
    case :ets.lookup(@ets_table, name) do
      [{^name, module, _type, _perms}] -> {:ok, module}
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
    |> Enum.map(fn {name, module, _type, _perms} -> {name, module} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "List all skills with type and permissions."
  @spec list_all_with_type() :: [{String.t(), module(), :core | :dynamic, :all | [atom()]}]
  def list_all_with_type do
    @ets_table
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Get permissions for a module."
  @spec get_permissions(module()) :: :all | [atom()] | nil
  def get_permissions(module) do
    case :ets.match(@ets_table, {:_, module, :_, :"$1"}) do
      [[perms]] -> perms
      _ -> nil
    end
  end

  @doc "Load a dynamic skill from a file in the skills directory."
  def load_skill(file_path) do
    GenServer.call(__MODULE__, {:load_skill, file_path}, 30_000)
  end

  @doc "Unload a dynamic skill by name."
  def unload_skill(name) do
    GenServer.call(__MODULE__, {:unload_skill, name})
  end

  @doc "Reload a dynamic skill by name."
  def reload_skill(name) do
    GenServer.call(__MODULE__, {:reload_skill, name})
  end

  @doc "Create a template skill file in the skills directory."
  def create_skill(name) do
    GenServer.call(__MODULE__, {:create_skill, name})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    # Register core skills
    for {name, module} <- @core_skills do
      :ets.insert(table, {name, module, :core, :all})
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
              :ets.insert(@ets_table, {skill.name, module, :dynamic, permissions})
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
         {:ok, _record} <-
           persist_skill(
             skill_name_from_module(module),
             to_string(module),
             file_path,
             permissions,
             compute_checksum(source)
           ) do
      skill_name = skill_name_from_module(module)
      :ets.insert(@ets_table, {skill_name, module, :dynamic, permissions})
      broadcast({:skill_registered, skill_name})
      Logger.info("Dynamic skill loaded: #{skill_name} with permissions: #{inspect(permissions)}")
      {:ok, %{name: skill_name, module: module, permissions: permissions}}
    end
  end

  defp do_unload_skill(name) do
    case :ets.lookup(@ets_table, name) do
      [{^name, _module, :core, _}] ->
        {:error, :cannot_unload_core}

      [{^name, module, :dynamic, _}] ->
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
          [{^name, old_module, :dynamic, _}] ->
            :code.purge(old_module)
            :code.delete(old_module)

          _ ->
            :ok
        end

        with {:ok, source} <- File.read(full_path),
             {:ok, module, permissions} <- compile_and_validate(full_path) do
          checksum = compute_checksum(source)

          Repo.update!(
            DynamicSkill.changeset(record, %{
              checksum: checksum,
              permissions: Enum.map(permissions, &to_string/1),
              module_name: to_string(module)
            })
          )

          :ets.insert(@ets_table, {name, module, :dynamic, permissions})
          broadcast({:skill_registered, name})
          Logger.info("Dynamic skill reloaded: #{name}")
          {:ok, %{name: name, module: module, permissions: permissions}}
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

          {:ok, "Hello from #{name}!"}
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
        module_str = to_string(module) |> String.replace_leading("Elixir.", "")

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
              :ok -> {:ok, module, permissions}
              error -> error
            end
        end

      [] ->
        {:error, :no_module_defined}
    end
  rescue
    e ->
      {:error, {:compilation_error, Exception.message(e)}}
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

  defp persist_skill(name, module_name, file_path, permissions, checksum) do
    import Ecto.Query
    perm_strings = Enum.map(permissions, &to_string/1)

    attrs = %{
      name: name,
      module_name: module_name,
      file_path: file_path,
      permissions: perm_strings,
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
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(AlexClaw.PubSub, @pubsub_topic, message)
  end

  defp notify_checksum_mismatch(skill_name) do
    Task.start(fn ->
      AlexClaw.Gateway.send_message(
        "Warning: Dynamic skill '#{skill_name}' file changed since last load. " <>
          "Use /skill reload #{skill_name} to update, or /skill unload #{skill_name} to remove."
      )
    end)
  end
end
