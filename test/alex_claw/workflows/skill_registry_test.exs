defmodule AlexClaw.Workflows.SkillRegistryTest do
  use AlexClaw.DataCase

  alias AlexClaw.Workflows.SkillRegistry

  describe "resolve/1" do
    test "resolves all registered skills" do
      for name <- SkillRegistry.list_skills() do
        assert {:ok, module} = SkillRegistry.resolve(name)
        assert is_atom(module)
      end
    end

    test "resolves known skills to correct modules" do
      assert {:ok, AlexClaw.Skills.RSSCollector} = SkillRegistry.resolve("rss_collector")
      assert {:ok, AlexClaw.Skills.WebSearch} = SkillRegistry.resolve("web_search")
      assert {:ok, AlexClaw.Skills.WebBrowse} = SkillRegistry.resolve("web_browse")
      assert {:ok, AlexClaw.Skills.TelegramNotify} = SkillRegistry.resolve("telegram_notify")
      assert {:ok, AlexClaw.Skills.ApiRequest} = SkillRegistry.resolve("api_request")
    end

    test "returns error for unknown skill" do
      assert {:error, :unknown_skill} = SkillRegistry.resolve("nonexistent")
      assert {:error, :unknown_skill} = SkillRegistry.resolve("")
    end
  end

  describe "list_skills/0" do
    test "returns sorted list of skill names" do
      skills = SkillRegistry.list_skills()
      assert is_list(skills)
      assert skills == Enum.sort(skills)
      assert "rss_collector" in skills
      assert "telegram_notify" in skills
      assert "api_request" in skills
    end

    test "includes all 12 core skills" do
      assert length(SkillRegistry.list_skills()) >= 12
    end
  end

  describe "list_all/0" do
    test "returns {name, module} pairs sorted by name" do
      pairs = SkillRegistry.list_all()
      assert is_list(pairs)
      names = Enum.map(pairs, &elem(&1, 0))
      assert names == Enum.sort(names)
      assert {"rss_collector", AlexClaw.Skills.RSSCollector} in pairs
    end
  end

  describe "list_all_with_type/0" do
    test "returns core skills with :all permissions and external flag" do
      entries = SkillRegistry.list_all_with_type()
      assert is_list(entries)

      rss = Enum.find(entries, fn {name, _, _, _, _, _} -> name == "rss_collector" end)
      assert {"rss_collector", AlexClaw.Skills.RSSCollector, :core, :all, _routes, true} = rss
    end

    test "all core skills have type :core" do
      entries = SkillRegistry.list_all_with_type()

      for {_name, _mod, type, perms, _routes, _ext} <- entries do
        if type == :core, do: assert(perms == :all)
      end
    end
  end

  describe "get_permissions/1" do
    test "returns :all for core skills" do
      assert :all = SkillRegistry.get_permissions(AlexClaw.Skills.RSSCollector)
    end

    test "returns nil for unknown module" do
      assert nil == SkillRegistry.get_permissions(NonExistent.Module)
    end
  end

  describe "dynamic skill loading" do
    setup do
      skills_dir = Application.get_env(:alex_claw, :skills_dir)
      File.mkdir_p!(skills_dir)
      on_exit(fn -> File.rm_rf!(skills_dir) end)
      %{skills_dir: skills_dir}
    end

    test "create_skill generates a template file", %{skills_dir: dir} do
      assert {:ok, "echo.ex"} = SkillRegistry.create_skill("echo")
      assert File.exists?(Path.join(dir, "echo.ex"))
      content = File.read!(Path.join(dir, "echo.ex"))
      assert content =~ "AlexClaw.Skills.Dynamic.Echo"
      assert content =~ "@behaviour AlexClaw.Skill"
      assert content =~ "def permissions"
    end

    test "create_skill returns error if file exists", %{skills_dir: dir} do
      File.write!(Path.join(dir, "echo.ex"), "# exists")
      assert {:error, :already_exists} = SkillRegistry.create_skill("echo")
    end

    test "load_skill compiles and registers with permissions/0 callback", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.TestLoader do
        @behaviour AlexClaw.Skill

        @impl true
        def permissions, do: [:llm, :web_read]

        @impl true
        def description, do: "test loader"

        @impl true
        def run(_args), do: {:ok, "loaded"}
      end
      """

      File.write!(Path.join(dir, "test_loader.ex"), source)

      assert {:ok, %{name: "test_loader", permissions: [:llm, :web_read]}} =
               SkillRegistry.load_skill("test_loader.ex")

      assert {:ok, AlexClaw.Skills.Dynamic.TestLoader} = SkillRegistry.resolve("test_loader")

      # Verify in list
      assert "test_loader" in SkillRegistry.list_skills()

      # Verify type and permissions
      entries = SkillRegistry.list_all_with_type()
      entry = Enum.find(entries, fn {name, _, _, _, _, _} -> name == "test_loader" end)
      assert {"test_loader", _, :dynamic, [:llm, :web_read], _routes, false} = entry

      # Verify get_permissions
      assert [:llm, :web_read] = SkillRegistry.get_permissions(AlexClaw.Skills.Dynamic.TestLoader)

      # Cleanup
      SkillRegistry.unload_skill("test_loader")
    end

    test "load_skill with no permissions declared defaults to empty list", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.NoPerms do
        @behaviour AlexClaw.Skill
        @impl true
        def run(_args), do: {:ok, "no perms"}
      end
      """

      File.write!(Path.join(dir, "no_perms.ex"), source)
      assert {:ok, %{name: "no_perms", permissions: []}} = SkillRegistry.load_skill("no_perms.ex")
      SkillRegistry.unload_skill("no_perms")
    end

    test "load_skill rejects invalid namespace", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.BadNamespace do
        @behaviour AlexClaw.Skill
        @impl true
        def run(_args), do: {:ok, "bad"}
      end
      """

      File.write!(Path.join(dir, "bad.ex"), source)
      assert {:error, {:invalid_namespace, _}} = SkillRegistry.load_skill("bad.ex")
    end

    test "load_skill rejects missing run/1", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.NoRun do
        def hello, do: :world
      end
      """

      File.write!(Path.join(dir, "no_run.ex"), source)
      assert {:error, :missing_run_callback} = SkillRegistry.load_skill("no_run.ex")
    end

    test "load_skill rejects unknown permissions", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.BadPerms do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:llm, :nuclear_launch]
        @impl true
        def run(_args), do: {:ok, "bad"}
      end
      """

      File.write!(Path.join(dir, "bad_perms.ex"), source)
      assert {:error, {:unknown_permissions, [:nuclear_launch]}} = SkillRegistry.load_skill("bad_perms.ex")
    end

    test "load_skill rejects path traversal" do
      assert {:error, :path_traversal} = SkillRegistry.load_skill("../../../etc/passwd")
    end

    test "load_skill rejects file not found" do
      assert {:error, :file_not_found} = SkillRegistry.load_skill("nonexistent.ex")
    end

    test "load_skill rejects name conflict with core", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.RssCollector do
        @behaviour AlexClaw.Skill
        @impl true
        def run(_args), do: {:ok, "fake rss"}
      end
      """

      File.write!(Path.join(dir, "rss_collector.ex"), source)
      assert {:error, :name_conflicts_with_core} = SkillRegistry.load_skill("rss_collector.ex")
      :code.purge(AlexClaw.Skills.Dynamic.RssCollector)
      :code.delete(AlexClaw.Skills.Dynamic.RssCollector)
    end

    test "unload_skill removes dynamic skill", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.Removable do
        @behaviour AlexClaw.Skill
        @impl true
        def run(_args), do: {:ok, "remove me"}
      end
      """

      File.write!(Path.join(dir, "removable.ex"), source)
      {:ok, _} = SkillRegistry.load_skill("removable.ex")
      assert :ok = SkillRegistry.unload_skill("removable")
      assert {:error, :unknown_skill} = SkillRegistry.resolve("removable")
    end

    test "unload_skill returns not_found for unknown" do
      assert {:error, :not_found} = SkillRegistry.unload_skill("does_not_exist")
    end

    test "cannot unload core skills" do
      assert {:error, :cannot_unload_core} = SkillRegistry.unload_skill("rss_collector")
    end

    test "reload_skill recompiles and updates permissions", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.Reloadable do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:llm]
        @impl true
        def version, do: "1.0.0"
        @impl true
        def run(_args), do: {:ok, "v1"}
      end
      """

      File.write!(Path.join(dir, "reloadable.ex"), source)
      {:ok, _} = SkillRegistry.load_skill("reloadable.ex")

      # Update the file with new permissions and version
      source_v2 = """
      defmodule AlexClaw.Skills.Dynamic.Reloadable do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:llm, :web_read]
        @impl true
        def version, do: "2.0.0"
        @impl true
        def run(_args), do: {:ok, "v2"}
      end
      """

      File.write!(Path.join(dir, "reloadable.ex"), source_v2)
      assert {:ok, %{permissions: [:llm, :web_read]}} = SkillRegistry.reload_skill("reloadable")

      # Verify updated permissions in ETS
      assert [:llm, :web_read] = SkillRegistry.get_permissions(AlexClaw.Skills.Dynamic.Reloadable)

      # Cleanup
      SkillRegistry.unload_skill("reloadable")
    end

    test "reload_skill returns not_found for unknown" do
      assert {:error, :not_found} = SkillRegistry.reload_skill("does_not_exist")
    end

    test "load_skill persists to database", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.Persisted do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:llm]
        @impl true
        def run(_args), do: {:ok, "persisted"}
      end
      """

      File.write!(Path.join(dir, "persisted.ex"), source)
      {:ok, _} = SkillRegistry.load_skill("persisted.ex")

      # Check DB record exists
      import Ecto.Query
      record = AlexClaw.Repo.one(from d in AlexClaw.Skills.DynamicSkill, where: d.name == "persisted")
      assert record != nil
      assert record.name == "persisted"
      assert record.file_path == "persisted.ex"
      assert record.enabled == true
      assert record.checksum != nil
      assert "llm" in record.permissions

      # Cleanup
      SkillRegistry.unload_skill("persisted")
    end

    test "unload_skill removes from database", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.DbRemove do
        @behaviour AlexClaw.Skill
        @impl true
        def run(_args), do: {:ok, "remove"}
      end
      """

      File.write!(Path.join(dir, "db_remove.ex"), source)
      {:ok, _} = SkillRegistry.load_skill("db_remove.ex")
      SkillRegistry.unload_skill("db_remove")

      import Ecto.Query
      record = AlexClaw.Repo.one(from d in AlexClaw.Skills.DynamicSkill, where: d.name == "db_remove")
      assert record == nil
    end
  end

  describe "get_routes/1" do
    test "returns custom routes for core skills that declare them" do
      assert [:on_items, :on_empty, :on_error] = SkillRegistry.get_routes("rss_collector")
      assert [:on_2xx, :on_4xx, :on_5xx, :on_timeout, :on_error] = SkillRegistry.get_routes("api_request")
      assert [:on_delivered, :on_error] = SkillRegistry.get_routes("telegram_notify")
      assert [:on_results, :on_no_results, :on_timeout, :on_error] = SkillRegistry.get_routes("web_search")
      assert [:on_clean, :on_findings, :on_error] = SkillRegistry.get_routes("github_security_review")
    end

    test "returns default routes for skills without routes/0" do
      assert [:on_success, :on_error] = SkillRegistry.get_routes("conversational")
      assert [:on_success, :on_error] = SkillRegistry.get_routes("llm_transform")
    end

    test "returns default routes for unknown skill" do
      assert [:on_success, :on_error] = SkillRegistry.get_routes("nonexistent_skill")
    end
  end

  describe "routes in ETS tuple" do
    test "list_all_with_type includes routes in 5th position" do
      entries = SkillRegistry.list_all_with_type()

      rss = Enum.find(entries, fn {name, _, _, _, _, _} -> name == "rss_collector" end)
      assert {_, _, :core, :all, [:on_items, :on_empty, :on_error], true} = rss
    end
  end

  describe "external?/1" do
    test "returns true for core skills tagged @external" do
      assert SkillRegistry.external?("web_search")
      assert SkillRegistry.external?("web_browse")
      assert SkillRegistry.external?("api_request")
      assert SkillRegistry.external?("rss_collector")
      assert SkillRegistry.external?("github_security_review")
      assert SkillRegistry.external?("google_calendar")
      assert SkillRegistry.external?("google_tasks")
      assert SkillRegistry.external?("web_automation")
      assert SkillRegistry.external?("research")
    end

    test "returns false for internal core skills" do
      refute SkillRegistry.external?("conversational")
      refute SkillRegistry.external?("telegram_notify")
      refute SkillRegistry.external?("discord_notify")
      refute SkillRegistry.external?("shell")
      refute SkillRegistry.external?("coder")
      refute SkillRegistry.external?("db_backup")
    end

    test "returns false for unknown skill" do
      refute SkillRegistry.external?("nonexistent")
    end
  end

  describe "AST-based external detection" do
    setup do
      skills_dir = Application.get_env(:alex_claw, :skills_dir)
      File.mkdir_p!(skills_dir)
      on_exit(fn -> File.rm_rf!(skills_dir) end)
      %{skills_dir: skills_dir}
    end

    test "rejects dynamic skill with undeclared Req.get call", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.SneakyFetcher do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:web_read]
        @impl true
        def run(args) do
          {:ok, resp} = Req.get(args[:input])
          {:ok, resp.body, :on_success}
        end
      end
      """

      File.write!(Path.join(dir, "sneaky_fetcher.ex"), source)
      assert {:error, {:undeclared_external, [{Req, :get}]}} = SkillRegistry.load_skill("sneaky_fetcher.ex")
      # Module should have been purged
      refute Code.ensure_loaded?(AlexClaw.Skills.Dynamic.SneakyFetcher)
    end

    test "rejects dynamic skill with undeclared SkillAPI.http_get call", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.SneakyApi do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:web_read]
        @impl true
        def run(args) do
          {:ok, resp} = AlexClaw.Skills.SkillAPI.http_get(__MODULE__, args[:input])
          {:ok, resp.body, :on_success}
        end
      end
      """

      File.write!(Path.join(dir, "sneaky_api.ex"), source)
      assert {:error, {:undeclared_external, [{AlexClaw.Skills.SkillAPI, :http_get}]}} = SkillRegistry.load_skill("sneaky_api.ex")
    end

    test "accepts dynamic skill with @external true and HTTP calls", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.HonestFetcher do
        @behaviour AlexClaw.Skill
        @impl true
        def external, do: true
        @impl true
        def permissions, do: [:web_read]
        @impl true
        def run(args) do
          {:ok, resp} = Req.get(args[:input])
          {:ok, resp.body, :on_success}
        end
      end
      """

      File.write!(Path.join(dir, "honest_fetcher.ex"), source)
      assert {:ok, %{name: "honest_fetcher", external: true}} = SkillRegistry.load_skill("honest_fetcher.ex")
      assert SkillRegistry.external?("honest_fetcher")
      SkillRegistry.unload_skill("honest_fetcher")
    end

    test "accepts dynamic skill without HTTP calls and no @external", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.PureSkill do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:llm]
        @impl true
        def run(_args), do: {:ok, "pure", :on_success}
      end
      """

      File.write!(Path.join(dir, "pure_skill.ex"), source)
      assert {:ok, %{name: "pure_skill", external: false}} = SkillRegistry.load_skill("pure_skill.ex")
      refute SkillRegistry.external?("pure_skill")
      SkillRegistry.unload_skill("pure_skill")
    end

    test "detects erlang module calls like :gen_tcp.connect", %{skills_dir: dir} do
      source = """
      defmodule AlexClaw.Skills.Dynamic.TcpSkill do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:web_read]
        @impl true
        def run(_args) do
          {:ok, socket} = :gen_tcp.connect(~c"localhost", 80, [])
          {:ok, socket, :on_success}
        end
      end
      """

      File.write!(Path.join(dir, "tcp_skill.ex"), source)
      assert {:error, {:undeclared_external, [{:gen_tcp, :connect}]}} = SkillRegistry.load_skill("tcp_skill.ex")
    end
  end
end
