defmodule AlexClaw.Skills.CoderTruthTest do
  @moduledoc """
  coder reports a half-done request as half done (reports/SECOND_ROUND_SEAMS.md
  §5; 0.3.53).

  Asked to generate a skill AND create a workflow for it, coder returned
  `{:ok, "Skill X generated and loaded…", :on_created}` even when the
  workflow was not created (coder.ex:136–140) — nothing said so, not even
  the log.

  Now a skill that loaded with a workflow that failed takes the declared
  error route `:on_partial`, and the message names what was not created and
  why. A request that asked for no workflow is unchanged.

  The workflow creation is made to fail the way it fails in life: the name
  "Auto: <skill_name>" is already taken (workflow names are unique).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.{CodeGenerator, Coder}
  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.SkillRegistry
  alias AlexClawTest.LLMMock
  alias Ecto.Adapters.SQL.Sandbox

  @goal "reply with the word ok"

  setup ctx do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    LLMMock.use_mock(ctx)
    LLMMock.no_knowledge()
    # 0.3.54: the workflow coder creates ends with a telegram_notify step,
    # saved only when Telegram is configured.
    AlexClawTest.TelegramStub.accept_all()

    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)

    name = CodeGenerator.derive_skill_name(@goal)
    module = "AlexClaw.Skills.Dynamic.#{Macro.camelize(name)}"

    LLMMock.answer("""
    ```elixir
    defmodule #{module} do
      @behaviour AlexClaw.Skill
      @impl true
      def description, do: "Replies ok."
      @impl true
      def run(_args), do: {:ok, "ok", :on_success}
    end
    ```
    """)

    on_exit(fn ->
      SkillRegistry.unload_skill(name)
      File.rm_rf!(skills_dir)
    end)

    %{name: name}
  end

  test "the skill loads but the workflow is not created: partial, and said", %{name: name} do
    {:ok, _} = Workflows.create_workflow(%{name: "Auto: #{name}", enabled: true})

    result = Coder.run(%{config: %{"goal" => @goal, "create_workflow" => true}, input: nil})

    assert {:ok, message, :on_partial} = result
    assert :on_partial in AlexClaw.Skill.error_routes(Coder)
    assert message =~ name
    assert message =~ ~r/workflow/i
    assert message =~ ~r/not created/i
  end
end
