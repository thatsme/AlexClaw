defmodule AlexClaw.Workflows.ExternalCallAliasTest do
  @moduledoc """
  A dynamic skill that reaches outside must say so (`external/0` → true), and
  the check that finds its outside calls resolves aliases the way containment
  does (architect's review, before release).

  The load-time scan looked for `AlexClaw.Skills.SkillAPI.http_get` written in
  full; a skill with `alias AlexClaw.Skills.SkillAPI` calling
  `SkillAPI.http_get` was not seen, and loaded without declaring `external/0`
  — so its output skipped the sanitization external content gets.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows.SkillRegistry

  setup do
    dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp load(dir, name, body) do
    File.write!(Path.join(dir, "#{name}.ex"), """
    defmodule AlexClaw.Skills.Dynamic.#{Macro.camelize(name)} do
      @behaviour AlexClaw.Skill
      #{body}
      @impl true
      def description, do: "external probe"
      @impl true
      def permissions, do: [:web_read]
    end
    """)

    SkillRegistry.load_skill("#{name}.ex")
  end

  test "an aliased SkillAPI.http_get without external/0 is refused", %{dir: dir} do
    assert {:error, {:undeclared_external, [{AlexClaw.Skills.SkillAPI, :http_get}]}} =
             load(dir, "aliased_http", """
             alias AlexClaw.Skills.SkillAPI
             @impl true
             def run(%{input: url}), do: SkillAPI.http_get(__MODULE__, url)
             """)
  end

  test "the same call written in full is refused too", %{dir: dir} do
    assert {:error, {:undeclared_external, [{AlexClaw.Skills.SkillAPI, :http_get}]}} =
             load(dir, "full_http", """
             @impl true
             def run(%{input: url}), do: AlexClaw.Skills.SkillAPI.http_get(__MODULE__, url)
             """)
  end

  test "an aliased call with external/0 declared loads", %{dir: dir} do
    assert {:ok, %{name: "declared_http"}} =
             load(dir, "declared_http", """
             alias AlexClaw.Skills.SkillAPI
             @impl true
             def external, do: true
             @impl true
             def run(%{input: url}), do: SkillAPI.http_get(__MODULE__, url)
             """)
  end
end
