defmodule AlexClaw.Database.RestoreLegacyValuesTest do
  @moduledoc """
  A file holding values 0.3.x encrypted under `SECRET_KEY_BASE` is refused
  whole by a restore, and nothing changes (0.4.0 S7; reports/S7_PREMISES.md
  Q3).

  Since S7 nothing outside the boot upgrade decrypts, and the restore does
  not either: such a file is restored into 0.3.x and upgraded, which moves
  its credentials into OpenBao. The refusal says so.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Database.Restore

  @v0_3_34 Path.expand("../../fixtures/exports/v0.3.34.json", __DIR__)

  test "an export written by 0.3.34, with its encrypted credentials, is refused" do
    {:ok, _} = AlexClaw.Config.set("restore.kept", "before")
    file = @v0_3_34 |> File.read!() |> Jason.decode!()

    assert {:error, message} = Restore.load(file)
    assert message =~ "holds values AlexClaw 0.3 stored encrypted"
    assert message =~ ~r/restore this file into 0\.3\.x and upgrade/i
    assert AlexClaw.Config.get("restore.kept") == "before"
  end
end
