defmodule AlexClaw.Skills.ContainmentRecheckTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Repo
  alias AlexClaw.Skills.DynamicSkill
  alias AlexClaw.Workflows.SkillRegistry

  setup do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)

    on_exit(fn ->
      SkillRegistry.unload_skill("recheck")
      File.rm_rf!(skills_dir)
    end)

    %{skills_dir: skills_dir}
  end

  defp source(body) do
    """
    defmodule AlexClaw.Skills.Dynamic.Recheck do
      @behaviour AlexClaw.Skill
      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "recheck probe"
      @impl true
      def run(_args) do
        #{body}
      end
    end
    """
  end

  # Mirrors the state after a restart: the row is in the database, nothing is
  # registered in this VM yet, and the boot load decides whether to register it.
  defp persist_unregistered(dir, approval, body) do
    code = source(body)
    File.write!(Path.join(dir, "recheck.ex"), code)

    {:ok, _record} =
      %DynamicSkill{}
      |> DynamicSkill.changeset(%{
        name: "recheck",
        module_name: "Elixir.AlexClaw.Skills.Dynamic.Recheck",
        file_path: "recheck.ex",
        checksum: :crypto.hash(:sha256, code) |> Base.encode16(case: :lower),
        permissions: [],
        routes: [],
        origin: "generated",
        approval: approval
      })
      |> Repo.insert()

    :ok
  end

  describe "boot re-check of containment-approved skills" do
    test "one that still qualifies is loaded", %{skills_dir: dir} do
      :ok = persist_unregistered(dir, "containment", ~s|{:ok, "ok", :on_success}|)

      :ok = SkillRegistry.reload_persisted()

      assert {:ok, AlexClaw.Skills.Dynamic.Recheck} = SkillRegistry.resolve("recheck")
    end

    # The file was approved by a check, not by a person. If it no longer passes
    # that check — because it changed, or because the allowlist tightened — there
    # is nothing standing behind it.
    test "one that no longer qualifies is refused", %{skills_dir: dir} do
      :ok =
        persist_unregistered(
          dir,
          "containment",
          ~s|File.write!("/tmp/recheck_escaped", "x")\n        {:ok, "ok", :on_success}|
        )

      File.rm_rf!("/tmp/recheck_escaped")

      :ok = SkillRegistry.reload_persisted()

      assert {:error, :unknown_skill} = SkillRegistry.resolve("recheck")
      refute File.exists?("/tmp/recheck_escaped")
    end

    test "a TOTP-approved skill is not re-judged", %{skills_dir: dir} do
      # Calls File, so it would fail containment — but a person approved it.
      :ok =
        persist_unregistered(
          dir,
          "totp",
          ~s|_ = File.exists?("/tmp")\n        {:ok, "ok", :on_success}|
        )

      :ok = SkillRegistry.reload_persisted()

      assert {:ok, AlexClaw.Skills.Dynamic.Recheck} = SkillRegistry.resolve("recheck")
    end
  end
end
