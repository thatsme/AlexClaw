defmodule AlexClaw.Skills.DbBackupTest do
  @moduledoc """
  The skill had two independent faults, either of which alone stopped it
  working, and no test to catch either:

    * `backup.enabled` was compared against the boolean `true`, but settings are
      persisted as strings, so the guard was permanently false and `run/1`
      always reported `:backup_disabled`.
    * `@backup_dir` was referenced but never defined, so it evaluated to `nil`
      and would have failed the moment the guard let anything through.

  The second was masked by the first, which is why both survived.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config
  alias AlexClaw.Skills.DbBackup

  describe "skill contract" do
    test "declares the routes the workflow executor branches on" do
      assert DbBackup.routes() == [:on_success, :on_error]
    end

    test "declares a description and no step fields" do
      assert is_binary(DbBackup.description())
      assert DbBackup.description() != ""
      assert DbBackup.step_fields() == []
    end
  end

  describe "run/1" do
    test "reports :backup_disabled when the setting is off" do
      Config.set("backup.enabled", false)
      assert {:error, :backup_disabled} = DbBackup.run(%{})
    end

    test "reports :backup_disabled when the setting was never written" do
      assert Config.get("backup.enabled") == nil
      assert {:error, :backup_disabled} = DbBackup.run(%{})
    end

    # The regression test for both faults. Settings round-trip as strings, so
    # before the fix this returned {:error, :backup_disabled} however the value
    # was written. Reaching the mount check at all proves the guard now opens —
    # and reaching it without raising proves @backup_dir is a real path rather
    # than nil, since File.stat/1 raises on nil.
    test "gets past the enabled guard and fails on the mount check instead" do
      Config.set("backup.enabled", true)
      refute Config.get("backup.enabled") == true, "settings persist as strings"

      assert {:error, {:not_mounted, reason}} = DbBackup.run(%{})
      assert is_binary(reason)
      assert reason =~ "/app/backups"
    end

    test "treats the string \"true\" the same as the boolean" do
      Config.set("backup.enabled", "true")
      assert {:error, {:not_mounted, _}} = DbBackup.run(%{})
    end
  end
end
