defmodule AlexClaw.Skills.NoImportTest do
  @moduledoc """
  A dynamic skill cannot import anything (Kernel's defaults aside)
  (architect's review of SECURITY.md; S10 review C).

  After an `import`, the imported module's functions are local calls, and the
  containment check sees remote calls: `import Logger` then `configure/1`
  passed a rule that allows Logger's level functions only. With no import, every
  call to another module is written as a remote call, and checked. `require
  Logger` stays: Logger's level functions are macros, and a require brings no
  function into local scope.
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
    module = "AlexClaw.Skills.Dynamic.#{Macro.camelize(name)}"

    File.write!(Path.join(dir, "#{name}.ex"), """
    defmodule #{module} do
      @behaviour AlexClaw.Skill
      #{body}
      @impl true
      def description, do: "import probe"
    end
    """)

    SkillRegistry.load_skill("#{name}.ex")
  end

  for {what, import} <- [
        {"Logger", "import Logger"},
        {"Logger, only its level functions", "import Logger, only: [info: 1]"},
        {"the skill helpers", "import AlexClaw.Skills.Helpers"},
        {"Kernel itself", "import Kernel, except: [send: 2]"}
      ] do
    test "importing #{what} is refused", %{dir: dir} do
      assert {:error, {:forbidden_construct, construct}} =
               load(dir, "import_probe", """
               #{unquote(import)}
               @impl true
               def run(_args), do: {:ok, "ok", :on_success}
               """)

      assert construct =~ "import"
    end
  end

  test "Logger's configuration cannot be reached through an import", %{dir: dir} do
    assert {:error, _refused} =
             load(dir, "logger_config_probe", """
             import Logger
             @impl true
             def run(_args) do
               configure(level: :none)
               {:ok, "silenced", :on_success}
             end
             """)
  end

  test "require Logger and full calls to the helpers still load", %{dir: dir} do
    assert {:ok, %{name: "full_calls"}} =
             load(dir, "full_calls", """
             require Logger
             @impl true
             def run(%{input: text}) do
               Logger.info("probe")
               {:ok, AlexClaw.Skills.Helpers.sanitize_utf8(text), :on_success}
             end
             """)
  end
end
