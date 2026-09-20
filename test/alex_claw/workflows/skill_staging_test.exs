defmodule AlexClaw.Workflows.SkillStagingTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Dispatcher.AuthCommands
  alias AlexClaw.Message
  alias AlexClaw.Workflows.SkillRegistry

  setup do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)
    on_exit(fn -> File.rm_rf!(skills_dir) end)
    %{skills_dir: skills_dir}
  end

  defp skill_source(body) do
    """
    defmodule AlexClaw.Skills.Dynamic.Staged do
      @behaviour AlexClaw.Skill
      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "staged"
      @impl true
      def run(_args), do: {:ok, "#{body}", :on_success}
    end
    """
  end

  defp msg do
    %Message{
      text: "",
      chat_id: "123",
      from: "Test",
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: :test
    }
  end

  describe "uploads are staged, not live" do
    test "stage_upload writes to pending and not to the skills directory", %{skills_dir: dir} do
      tmp = Path.join(System.tmp_dir!(), "staged_upload.ex")
      File.write!(tmp, skill_source("uploaded"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:ok, "staged.ex"} = SkillRegistry.stage_upload(tmp, "staged.ex")

      assert File.exists?(Path.join([dir, "pending", "staged.ex"]))
      refute File.exists?(Path.join(dir, "staged.ex"))
    end

    # The whole point: the live file a running skill was loaded from must not
    # change until the 2FA code is verified.
    test "an upload cannot modify the live file of a loaded skill before 2FA", %{skills_dir: dir} do
      live = Path.join(dir, "staged.ex")
      File.write!(live, skill_source("original"))
      {:ok, _} = SkillRegistry.load_skill("staged.ex")
      on_exit(fn -> SkillRegistry.unload_skill("staged") end)

      tmp = Path.join(System.tmp_dir!(), "replacement.ex")
      File.write!(tmp, skill_source("replaced"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:ok, "staged.ex"} = SkillRegistry.stage_upload(tmp, "staged.ex")

      assert File.read!(live) =~ "original"
      refute File.read!(live) =~ "replaced"
      {:ok, module} = SkillRegistry.resolve("staged")
      assert module.run(%{}) == {:ok, "original", :on_success}
    end

    test "stage_upload still refuses a traversing filename", %{skills_dir: dir} do
      tmp = Path.join(System.tmp_dir!(), "evil.ex")
      File.write!(tmp, skill_source("evil"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert {:error, :invalid_filename} =
               SkillRegistry.stage_upload(tmp, "../../escaped.ex")

      refute File.exists?(Path.join([dir, "pending", "escaped.ex"]))
    end
  end

  describe "promotion on 2FA" do
    test "promote_pending moves the file into the live directory", %{skills_dir: dir} do
      tmp = Path.join(System.tmp_dir!(), "promote.ex")
      File.write!(tmp, skill_source("promoted"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, _} = SkillRegistry.stage_upload(tmp, "staged.ex")

      assert :ok = SkillRegistry.promote_pending("staged.ex")

      assert File.exists?(Path.join(dir, "staged.ex"))
      refute File.exists?(Path.join([dir, "pending", "staged.ex"]))
    end

    test "promote_pending reports :no_pending when nothing is staged" do
      assert :no_pending = SkillRegistry.promote_pending("absent.ex")
    end

    test "the 2FA action promotes and then loads", %{skills_dir: dir} do
      tmp = Path.join(System.tmp_dir!(), "via_2fa.ex")
      File.write!(tmp, skill_source("via_2fa"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, _} = SkillRegistry.stage_upload(tmp, "staged.ex")
      on_exit(fn -> SkillRegistry.unload_skill("staged") end)

      AuthCommands.execute_2fa_action(%{type: :skill_load, file_path: "staged.ex"}, msg())

      assert File.exists?(Path.join(dir, "staged.ex"))
      assert {:ok, AlexClaw.Skills.Dynamic.Staged} = SkillRegistry.resolve("staged")
    end

    # /skill load names a file already sitting in the skills directory.
    test "a file already in place still loads without staging", %{skills_dir: dir} do
      File.write!(Path.join(dir, "staged.ex"), skill_source("in_place"))
      on_exit(fn -> SkillRegistry.unload_skill("staged") end)

      AuthCommands.execute_2fa_action(%{type: :skill_load, file_path: "staged.ex"}, msg())

      assert {:ok, AlexClaw.Skills.Dynamic.Staged} = SkillRegistry.resolve("staged")
    end
  end
end
