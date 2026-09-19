defmodule AlexClaw.Config.EnabledTest do
  @moduledoc """
  `Config.get/2` returns what was persisted, and settings persist as strings.
  Comparing its result against the boolean `true` is therefore always false —
  the mistake that silently disabled the backup skill and the reverse-proxy
  header setting. `enabled?/1` exists so that question has one answer.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config

  describe "enabled?/1" do
    test "is true for a setting written as the boolean true" do
      Config.set("test.flag", true)
      assert Config.enabled?("test.flag")
    end

    test "is true for a setting written as the string \"true\"" do
      Config.set("test.flag", "true")
      assert Config.enabled?("test.flag")
    end

    test "is false for a setting written as false, either way" do
      Config.set("test.flag", false)
      refute Config.enabled?("test.flag")

      Config.set("test.flag", "false")
      refute Config.enabled?("test.flag")
    end

    test "is false for a setting that was never written" do
      refute Config.enabled?("test.never.written")
    end

    test "is false for values that are neither true nor false" do
      for value <- ["", "yes", "1", "TRUE", nil] do
        Config.set("test.flag", value)
        refute Config.enabled?("test.flag"), "expected #{inspect(value)} not to count as enabled"
      end
    end

    # The reason the helper exists: a direct comparison does not survive the
    # round-trip through storage.
    test "a boolean written as true does not compare equal to true on read" do
      Config.set("test.flag", true)
      assert Config.get("test.flag") == "true"
      refute Config.get("test.flag") == true
      assert Config.enabled?("test.flag")
    end
  end
end
