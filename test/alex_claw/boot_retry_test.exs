defmodule AlexClaw.BootRetryTest do
  @moduledoc """
  What the processes that read the database at boot do when it is not there.

  The app and postgres start together and one of them wins, so "the database is
  not up yet" is an ordinary condition at boot rather than a bug. Crashing on it
  restarts the process, which queries again, which crashes again — and the
  supervisor's restart intensity turns a boot that was merely early into the
  whole tree going down a few seconds later.

  A non-shared sandbox is what makes this testable without a second postgres.
  Ownership is checked out to the test process alone, so any query from another
  process fails, which is exactly what an unreachable server looks like from
  inside one. `Sandbox.allow/3` is then the database arriving.
  """
  use AlexClaw.DataCase, async: true
  @moduletag :integration

  alias AlexClaw.BootRetry
  alias AlexClaw.Skills.DynamicSkill
  alias AlexClaw.Workflows.SkillRegistry
  alias Ecto.Adapters.SQL.Sandbox

  @skill "bootretry"
  @module "Elixir.AlexClaw.Skills.Dynamic.Bootretry"

  setup do
    dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      SkillRegistry.unload_skill(@skill)
      File.rm(Path.join(dir, "#{@skill}.ex"))
    end)

    %{dir: dir, registry: Process.whereis(SkillRegistry)}
  end

  describe "the backoff schedule" do
    test "is 1s, 2s, 5s and then every 10s" do
      assert Enum.map(0..5, &BootRetry.delay/1) ==
               [1_000, 2_000, 5_000, 10_000, 10_000, 10_000]
    end
  end

  describe "a database the registry cannot reach" do
    test "does not take the process down", %{registry: registry} do
      ref = Process.monitor(registry)

      send(registry, :load_dynamic_skills)

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 300
      assert Process.alive?(registry)
      assert Process.whereis(SkillRegistry) == registry, "the registry was restarted"
    end

    test "leaves the core skills registered", %{registry: registry} do
      send(registry, :load_dynamic_skills)
      Process.sleep(50)

      assert {:ok, AlexClaw.Skills.Shell} = SkillRegistry.resolve("shell")
    end

    # The whole point of the retry: the load is owed, not abandoned.
    test "loads the dynamic skills once the database answers", ctx do
      persist_unregistered(ctx.dir)

      send(ctx.registry, :load_dynamic_skills)
      Process.sleep(50)

      assert SkillRegistry.resolve(@skill) == {:error, :unknown_skill},
             "the skill loaded while the database was unreachable"

      # The database arrives. The retry scheduled by the failed attempt is what
      # picks it up — nothing here asks for the load a second time.
      Sandbox.allow(Repo, self(), ctx.registry)

      assert eventually(fn -> SkillRegistry.resolve(@skill) != {:error, :unknown_skill} end),
             "the retry never loaded the skill after the database came back"
    end
  end

  # The first backoff is 1s, so this has to outlast it.
  defp eventually(check, remaining_ms \\ 4_000)
  defp eventually(_check, remaining_ms) when remaining_ms <= 0, do: false

  defp eventually(check, remaining_ms) do
    case check.() do
      true ->
        true

      false ->
        Process.sleep(100)
        eventually(check, remaining_ms - 100)
    end
  end

  defp persist_unregistered(dir) do
    code = """
    defmodule AlexClaw.Skills.Dynamic.Bootretry do
      @behaviour AlexClaw.Skill
      @impl true
      def version, do: "1.0.0"
      @impl true
      def description, do: "boot retry probe"
      @impl true
      def run(_args), do: {:ok, "ok", :on_success}
    end
    """

    File.write!(Path.join(dir, "#{@skill}.ex"), code)

    {:ok, _record} =
      %DynamicSkill{}
      |> DynamicSkill.changeset(%{
        name: @skill,
        module_name: @module,
        file_path: "#{@skill}.ex",
        checksum: :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower),
        permissions: [],
        routes: [],
        origin: "generated",
        approval: "containment"
      })
      |> Repo.insert()

    :ok
  end
end
