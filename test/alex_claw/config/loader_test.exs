defmodule AlexClaw.Config.LoaderTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias AlexClaw.Config.Loader

  # The migration narrows an untouched allowlist and leaves a customised one
  # alone. Left alone is not the same as left unsaid.
  describe "shell allowlist report" do
    test "names the withdrawn prefixes a configured list still grants" do
      insert_setting("shell.whitelist", ~s(["df","curl","bin/alex_claw"]), category: "shell")

      log =
        capture_log(fn ->
          assert {:noreply, %{}} = Loader.handle_info(:audit_shell_allowlist, %{})
        end)

      assert log =~ "shell.whitelist still allows prefixes the default dropped in 0.3.22"
      assert log =~ "curl"
      assert log =~ "bin/alex_claw"
    end

    test "says nothing when the compiled default is in force" do
      log = capture_log(fn -> Loader.handle_info(:audit_shell_allowlist, %{}) end)

      refute log =~ "still allows prefixes"
    end

    test "says nothing for a customised list that grants none of them" do
      insert_setting("shell.whitelist", ~s(["df","my-own-tool"]), category: "shell")

      log = capture_log(fn -> Loader.handle_info(:audit_shell_allowlist, %{}) end)

      refute log =~ "still allows prefixes"
    end
  end
end
