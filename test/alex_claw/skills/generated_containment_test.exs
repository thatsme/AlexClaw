defmodule AlexClaw.Skills.GeneratedContainmentTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Repo
  alias AlexClaw.Skills.DynamicSkill
  alias AlexClaw.Workflows.SkillRegistry

  setup do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)
    on_exit(fn -> File.rm_rf!(skills_dir) end)
    %{skills_dir: skills_dir}
  end

  defp contained_source do
    """
    defmodule AlexClaw.Skills.Dynamic.GenContained do
      @behaviour AlexClaw.Skill
      alias AlexClaw.Skills.SkillAPI

      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "contained probe"
      @impl true
      def permissions, do: [:llm]
      @impl true
      def run(args) do
        text = args |> Map.get(:input, "") |> to_string() |> String.trim()
        {:ok, "handled " <> text, :on_success}
      end
    end
    """
  end

  defp escaping_source do
    """
    defmodule AlexClaw.Skills.Dynamic.GenEscaping do
      @behaviour AlexClaw.Skill
      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "escaping probe"
      @impl true
      def run(_args) do
        File.write!("/tmp/gen_escaped", "x")
        {:ok, "done", :on_success}
      end
    end
    """
  end

  describe "vet_pending/1" do
    test "contained source is reported contained and leaves nothing resident" do
      :ok = SkillRegistry.write_pending("gen_contained.ex", contained_source())

      assert {:ok, %{contained: :ok, module: module, permissions: perms}} =
               SkillRegistry.vet_pending("gen_contained.ex")

      assert module == AlexClaw.Skills.Dynamic.GenContained
      assert :llm in perms

      # Vetting must not leave the module loaded.
      refute :erlang.module_loaded(module)
    end

    test "escaping source is reported with its violations" do
      :ok = SkillRegistry.write_pending("gen_escaping.ex", escaping_source())

      assert {:ok, %{contained: {:error, violations}}} =
               SkillRegistry.vet_pending("gen_escaping.ex")

      assert Enum.any?(violations, &String.contains?(&1, "File.write!"))
    end

    test "vetting does not run the code" do
      :ok = SkillRegistry.write_pending("gen_escaping.ex", escaping_source())
      File.rm_rf!("/tmp/gen_escaped")

      {:ok, _verdict} = SkillRegistry.vet_pending("gen_escaping.ex")

      refute File.exists?("/tmp/gen_escaped")
    end

    test "source rejected by the AST gate is an error, not a verdict" do
      :ok =
        SkillRegistry.write_pending("gen_gated.ex", """
        defmodule AlexClaw.Skills.Dynamic.GenGated do
          @behaviour AlexClaw.Skill
          use GenServer
          @impl true
          def run(_args), do: {:ok, "ok", :on_success}
          @impl true
          def description, do: "gated"
        end
        """)

      assert {:error, {:forbidden_construct, _}} = SkillRegistry.vet_pending("gen_gated.ex")
    end
  end

  describe "staging" do
    test "write_pending never touches the live directory", %{skills_dir: dir} do
      :ok = SkillRegistry.write_pending("gen_contained.ex", contained_source())

      assert File.exists?(Path.join([dir, "pending", "gen_contained.ex"]))
      refute File.exists?(Path.join(dir, "gen_contained.ex"))
    end

    test "a traversing filename is refused" do
      assert {:error, :invalid_filename} =
               SkillRegistry.write_pending("../escape.ex", contained_source())
    end
  end

  defp source_with(permissions, body \\ ~s|{:ok, "ok", :on_success}|) do
    """
    defmodule AlexClaw.Skills.Dynamic.GenPerms do
      @behaviour AlexClaw.Skill
      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "permission probe"
      @impl true
      def permissions, do: #{inspect(permissions)}
      @impl true
      def run(_args) do
        #{body}
      end
    end
    """
  end

  # Containment bounds which modules the code may call. It cannot bound what
  # SkillAPI does for it, so the permissions are capped separately.
  describe "permission ceiling" do
    test "contained code declaring :skill_invoke does not auto-load" do
      :ok = SkillRegistry.write_pending("gen_perms.ex", source_with([:llm, :skill_invoke]))

      assert {:ok, %{contained: {:error, reasons}}} = SkillRegistry.vet_pending("gen_perms.ex")
      assert Enum.any?(reasons, &String.contains?(&1, ":skill_invoke"))
    end

    test "contained code declaring :config_read does not auto-load" do
      :ok = SkillRegistry.write_pending("gen_perms.ex", source_with([:config_read]))

      assert {:ok, %{contained: {:error, reasons}}} = SkillRegistry.vet_pending("gen_perms.ex")
      assert Enum.any?(reasons, &String.contains?(&1, ":config_read"))
    end

    test ":web_read with :memory_read does not auto-load" do
      :ok = SkillRegistry.write_pending("gen_perms.ex", source_with([:web_read, :memory_read]))

      assert {:ok, %{contained: {:error, reasons}}} = SkillRegistry.vet_pending("gen_perms.ex")
      assert Enum.any?(reasons, &String.contains?(&1, "web_read together with"))
    end

    test ":llm with :web_read auto-loads" do
      :ok = SkillRegistry.write_pending("gen_perms.ex", source_with([:llm, :web_read]))

      assert {:ok, %{contained: :ok}} = SkillRegistry.vet_pending("gen_perms.ex")
    end

    test "call violations and permission violations are reported together" do
      :ok =
        SkillRegistry.write_pending(
          "gen_perms.ex",
          source_with([:skill_invoke], """
          File.write!("/tmp/x", "y")
                {:ok, "ok", :on_success}
          """)
        )

      assert {:ok, %{contained: {:error, reasons}}} = SkillRegistry.vet_pending("gen_perms.ex")
      assert Enum.any?(reasons, &String.contains?(&1, "File.write!"))
      assert Enum.any?(reasons, &String.contains?(&1, ":skill_invoke"))
    end
  end

  describe "provenance of a contained load" do
    test "promoting and loading records containment approval", %{skills_dir: dir} do
      :ok = SkillRegistry.write_pending("gen_contained.ex", contained_source())
      {:ok, %{contained: :ok}} = SkillRegistry.vet_pending("gen_contained.ex")

      :ok = SkillRegistry.promote_pending("gen_contained.ex")

      {:ok, _info} =
        SkillRegistry.load_skill("gen_contained.ex", origin: "generated", approval: "containment")

      on_exit(fn -> SkillRegistry.unload_skill("gen_contained") end)

      assert %{origin: "generated", approval: "containment"} =
               Repo.get_by(DynamicSkill, name: "gen_contained")

      assert File.exists?(Path.join(dir, "gen_contained.ex"))
    end
  end
end
