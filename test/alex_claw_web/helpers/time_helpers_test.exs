defmodule AlexClawWeb.TimeHelpersTest do
  use AlexClaw.DataCase, async: false

  alias AlexClawWeb.TimeHelpers

  describe "format_datetime/1" do
    test "returns empty string for nil" do
      assert TimeHelpers.format_datetime(nil) == ""
    end

    test "formats UTC DateTime" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-03-24T10:30:00Z")
      result = TimeHelpers.format_datetime(dt)
      assert result =~ "2026-03-24"
      assert result =~ "10:30:00"
    end

    test "formats NaiveDateTime" do
      ndt = ~N[2026-03-24 10:30:00]
      result = TimeHelpers.format_datetime(ndt)
      assert result =~ "2026-03-24"
    end

    test "uses configured timezone" do
      insert_setting("display.timezone", "Europe/Rome", type: "string", category: "display")
      {:ok, dt, _} = DateTime.from_iso8601("2026-03-24T10:00:00Z")
      result = TimeHelpers.format_datetime(dt)
      assert result =~ "2026-03-24"
      assert result =~ "11:00:00"
    end
  end
end
