defmodule AlexClaw.Skills.ContainmentAllTest do
  @moduledoc """
  Every dynamic skill runs under containment, whoever approved it
  (THREAT_MODEL.md P9; reports/S6_PREMISES.md §3; 0.4.0 S6).

  - The checker no longer refuses what cannot run: a typespec naming a remote
    type, and string interpolation (Kernel.to_string/1).
  - Four functions are allowed one by one — a clock, a sleep, an exception's
    message, a hash — while the rest of their modules stays out.
  - Two SkillAPI doors replace what the scrapers did directly:
    `parallel_map/4` (bounded concurrency) and `module_docs/2`.
  - A skill approved with a code is contained like any other: at load and at
    every boot. A code approves the permissions it declares, which an
    unattended load could not hold; it does not approve calls outside the
    allowlist.
  - The approval names the permissions and the risky ones.
  - skill_source_indexer, which reads the skills directory and the app
    config, is a core skill.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.{CallPolicy, DynamicSkill, SkillAPI}
  alias AlexClaw.Workflows.SkillRegistry

  @fixtures "test/fixtures/skills"

  defp contained(source), do: source |> Code.string_to_quoted!() |> CallPolicy.contained?()

  defp skill(body, extra \\ "") do
    """
    defmodule AlexClaw.Skills.Dynamic.Probe do
      @behaviour AlexClaw.Skill
      #{extra}
      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "probe"
      @impl true
      def run(_args) do
        #{body}
      end
    end
    """
  end

  describe "the checker no longer refuses what cannot run" do
    test "a @spec naming a remote type is not a call" do
      source =
        skill(~s|{:ok, "ok", :on_success}|, """
        @impl true
        @spec config_schema() :: AlexClaw.Skill.config_schema()
        def config_schema, do: %{}
        """)

      assert :ok = contained(source)
    end

    test "string interpolation is not a call to Kernel" do
      assert :ok = contained(skill(~s|n = 3\n {:ok, "n=\#{n}", :on_success}|))
    end
  end

  describe "four functions are allowed, their modules are not" do
    test "a clock, a sleep, an exception's message and a hash" do
      body = """
      started = System.monotonic_time(:millisecond)
      Process.sleep(1)
      message = Exception.message(%RuntimeError{message: "x"})
      digest = :crypto.hash(:sha256, message)
      {:ok, {started, byte_size(digest)}, :on_success}
      """

      assert :ok = contained(skill(body))
    end

    for call <- [
          ~s|System.cmd("ls", [])|,
          ~s|System.get_env("SECRET_KEY_BASE")|,
          ~s|Process.put(:auth_token, nil)|,
          ~s|:crypto.strong_rand_bytes(8)|,
          ~s|:code.load_binary(Foo, ~c"foo", <<>>)|,
          ~s|Task.async_stream([1], fn x -> x end)|,
          ~s|Application.get_env(:alex_claw, :admin_password)|,
          ~s|File.read("/etc/passwd")|,
          ~s|File.ls("/app")|
        ] do
      test "#{call} stays out" do
        assert {:error, [_ | _]} = contained(skill(unquote(call)))
      end
    end
  end

  describe "the TOTP-approved skills" do
    for file <-
          ~w(create_top_5_hacker elixir_source_scraper hexdocs_guides_scraper lyse_scraper) do
      test "#{file} is contained as it is" do
        source = File.read!(Path.join(@fixtures, "#{unquote(file)}.ex"))
        assert :ok = contained(source)
      end
    end

    test "skill_source_indexer is not contained: it reads the filesystem and the app config" do
      source = File.read!(Path.join(@fixtures, "skill_source_indexer.ex"))
      assert {:error, violations} = contained(source)
      assert Enum.any?(violations, &(&1 =~ "File."))
      assert Enum.any?(violations, &(&1 =~ "Application.get_env"))
    end

    test "skill_source_indexer runs as a core skill" do
      assert {:ok, AlexClaw.Skills.SkillSourceIndexer} =
               SkillRegistry.resolve("skill_source_indexer")

      assert AlexClaw.Skills.SkillSourceIndexer in SkillRegistry.core_modules()
    end
  end

  describe "the SkillAPI doors the scrapers need" do
    test "parallel_map/4 maps with a bounded concurrency, in order" do
      assert {:ok, [2, 4, 6]} =
               SkillAPI.parallel_map(AlexClaw.Skills.RSSCollector, [1, 2, 3], &(&1 * 2),
                 max_concurrency: 2
               )
    end

    test "parallel_map/4 refuses a concurrency above its cap" do
      assert {:error, :too_much_concurrency} =
               SkillAPI.parallel_map(AlexClaw.Skills.RSSCollector, [1], & &1,
                 max_concurrency: 1_000
               )
    end

    test "module_docs/2 returns a loaded module's docs" do
      assert {:ok, {:docs_v1, _, _, _, _, _, _}} =
               SkillAPI.module_docs(AlexClaw.Skills.RSSCollector, Enum)
    end
  end

  describe "a skill approved with a code is contained too" do
    setup do
      dir = Application.get_env(:alex_claw, :skills_dir)
      File.mkdir_p!(dir)

      on_exit(fn ->
        SkillRegistry.unload_skill("probe")
        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    test "at load: an upload calling outside the allowlist is refused", %{dir: dir} do
      File.write!(Path.join(dir, "probe.ex"), skill(~s|File.read("/etc/hosts")|))

      assert {:error, {:not_contained, [_ | _]}} =
               SkillRegistry.load_skill("probe.ex", origin: "upload", approval: "totp")

      assert {:error, :unknown_skill} = SkillRegistry.resolve("probe")
    end

    test "at boot: a code-approved skill that is not contained is not loaded", %{dir: dir} do
      code = skill(~s|_ = File.exists?("/tmp")\n {:ok, "ok", :on_success}|)
      File.write!(Path.join(dir, "probe.ex"), code)

      {:ok, _} =
        %DynamicSkill{}
        |> DynamicSkill.changeset(%{
          name: "probe",
          module_name: "Elixir.AlexClaw.Skills.Dynamic.Probe",
          file_path: "probe.ex",
          checksum: :crypto.hash(:sha256, code) |> Base.encode16(case: :lower),
          permissions: [],
          routes: [],
          origin: "upload",
          approval: "totp"
        })
        |> Repo.insert()

      :ok = SkillRegistry.reload_persisted()

      assert {:error, :unknown_skill} = SkillRegistry.resolve("probe")
    end

    # The cap guards unattended loads, where the model wrote both the code and
    # its permissions. A person approved these.
    test "the permission cap does not apply to it", %{dir: dir} do
      File.write!(
        Path.join(dir, "probe.ex"),
        skill(~s|{:ok, "ok", :on_success}|, """
        @impl true
        def permissions, do: [:web_read, :knowledge_read, :knowledge_write]
        """)
      )

      assert {:ok, %{name: "probe"}} =
               SkillRegistry.load_skill("probe.ex", origin: "upload", approval: "totp")
    end
  end

  # Generation: a skill whose calls are contained but whose permissions exceed
  # the unattended cap can still be approved with a code; one that calls
  # outside the allowlist cannot. vet_pending/1 tells the two apart.
  describe "a generated skill's verdict" do
    setup do
      dir = Application.get_env(:alex_claw, :skills_dir)
      File.mkdir_p!(Path.join(dir, "pending"))
      on_exit(fn -> File.rm_rf!(dir) end)
      :ok
    end

    test "permissions over the cap: not unattended, but its calls are contained" do
      :ok =
        SkillRegistry.write_pending(
          "probe.ex",
          skill(~s|{:ok, "ok", :on_success}|, """
          @impl true
          def permissions, do: [:web_read, :knowledge_read]
          """)
        )

      assert {:ok, %{contained: {:error, [_ | _]}, calls: :ok}} =
               SkillRegistry.vet_pending("probe.ex")
    end

    test "a call outside the allowlist: its calls are not contained" do
      :ok = SkillRegistry.write_pending("probe.ex", skill(~s|File.read("/etc/hosts")|))

      assert {:ok, %{contained: {:error, _}, calls: {:error, [_ | _]}}} =
               SkillRegistry.vet_pending("probe.ex")
    end
  end

  describe "the approval names the permissions and the risky ones" do
    setup do
      dir = Application.get_env(:alex_claw, :skills_dir)
      File.mkdir_p!(Path.join(dir, "pending"))
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(
        Path.join([dir, "pending", "probe.ex"]),
        skill(~s|{:ok, "ok", :on_success}|, """
        @impl true
        def permissions, do: [:web_read, :knowledge_read, :knowledge_write]
        """)
      )

      :ok
    end

    test "describe_pending/1 lists the permissions and flags the risks" do
      assert {:ok, text} = SkillRegistry.describe_pending("probe.ex")

      for permission <- ~w(web_read knowledge_read knowledge_write) do
        assert text =~ permission
      end

      # knowledge_write: what it writes is read back into prompts.
      assert text =~ ~r/knowledge base/i
      # web_read with a private read: it can read and then send out.
      assert text =~ ~r/private/i
    end

    test "calls outside the allowlist are named: a code does not approve them" do
      dir = Application.get_env(:alex_claw, :skills_dir)
      File.write!(Path.join([dir, "pending", "probe.ex"]), skill(~s|File.read("/etc/hosts")|))

      assert {:ok, text} = SkillRegistry.describe_pending("probe.ex")
      assert text =~ "File.read/1"
      assert text =~ ~r/will not load/i
    end

    test "a skill with no risky permission gets no warning" do
      dir = Application.get_env(:alex_claw, :skills_dir)

      File.write!(
        Path.join([dir, "pending", "plain.ex"]),
        String.replace(skill(~s|{:ok, "ok", :on_success}|), "Probe", "Plain")
      )

      assert {:ok, text} = SkillRegistry.describe_pending("plain.ex")
      refute text =~ ~r/private|knowledge base/i
    end
  end
end
