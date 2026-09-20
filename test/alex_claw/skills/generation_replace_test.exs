defmodule AlexClaw.Skills.GenerationReplaceTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows.SkillRegistry

  setup do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)

    on_exit(fn ->
      SkillRegistry.unload_skill("weather")
      File.rm_rf!(skills_dir)
    end)

    %{skills_dir: skills_dir}
  end

  defp source(marker) do
    """
    defmodule AlexClaw.Skills.Dynamic.Weather do
      @behaviour AlexClaw.Skill
      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "#{marker}"
      @impl true
      def run(_args), do: {:ok, "#{marker}", :on_success}
    end
    """
  end

  describe "generation_may_replace?/1" do
    test "a free name is available" do
      assert :ok = SkillRegistry.generation_may_replace?("nothing_here")
    end

    test "a core skill name is refused" do
      assert {:error, {:would_replace, owner}} = SkillRegistry.generation_may_replace?("shell")
      assert owner =~ "core skill"
    end

    # The case that matters: an uploaded skill was approved by a person. A goal
    # deriving the same name must not quietly take it over.
    test "an uploaded skill is refused", %{skills_dir: dir} do
      File.write!(Path.join(dir, "weather.ex"), source("uploaded"))
      {:ok, _} = SkillRegistry.load_skill("weather.ex")

      assert {:error, {:would_replace, owner}} = SkillRegistry.generation_may_replace?("weather")
      assert owner =~ "uploaded"
    end

    test "a generated skill approved by TOTP is refused", %{skills_dir: dir} do
      File.write!(Path.join(dir, "weather.ex"), source("totp-approved"))
      {:ok, _} = SkillRegistry.load_skill("weather.ex", origin: "generated", approval: "totp")

      assert {:error, {:would_replace, owner}} = SkillRegistry.generation_may_replace?("weather")
      assert owner =~ "totp"
    end

    test "a generated skill approved by containment may be replaced", %{skills_dir: dir} do
      File.write!(Path.join(dir, "weather.ex"), source("generated"))

      {:ok, _} =
        SkillRegistry.load_skill("weather.ex", origin: "generated", approval: "containment")

      assert :ok = SkillRegistry.generation_may_replace?("weather")
    end
  end

  describe "the uploaded skill survives an attempt" do
    test "its file and module are untouched", %{skills_dir: dir} do
      live = Path.join(dir, "weather.ex")
      File.write!(live, source("uploaded"))
      {:ok, _} = SkillRegistry.load_skill("weather.ex")

      # Generation stages something different under the same name.
      :ok = SkillRegistry.write_pending("weather.ex", source("generated"))

      assert {:error, {:would_replace, _owner}} =
               SkillRegistry.generation_may_replace?("weather")

      # Refused before any promotion: the live file and the loaded module stand.
      assert File.read!(live) =~ "uploaded"
      assert {:ok, AlexClaw.Skills.Dynamic.Weather} = SkillRegistry.resolve("weather")
      {:ok, module} = SkillRegistry.resolve("weather")
      assert {:ok, "uploaded", :on_success} = module.run(%{})
    end
  end
end
