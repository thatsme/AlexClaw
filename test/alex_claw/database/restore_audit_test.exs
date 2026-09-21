defmodule AlexClaw.Database.RestoreAuditTest do
  @moduledoc """
  A restore is audited on both sides: a row before anything runs — and no
  restore without it — and a row saying how it ended.

  `run/2` shells out to psql against the live database, so a restore that
  actually runs is not exercised here; the paths that stop short of psql are.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias AlexClaw.Auth.AuditEntry
  alias AlexClaw.Database.Restore

  defp staged(contents) do
    source = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}.sql")
    File.write!(source, contents)
    {:ok, staged} = Restore.stage(source)
    File.rm(source)
    staged
  end

  defp rows(decision, fragment) do
    Repo.all(
      from(e in AuditEntry,
        where: e.decision == ^decision and like(e.reason, ^"%#{fragment}%"),
        order_by: e.id
      )
    )
  end

  # The challenge can be answered minutes later, by which time a tmp cleaner
  # may have taken the file. Shelling out to psql with a missing -f argument
  # would be a worse way to find out.
  test "a staged file that has disappeared is refused, and both rows say so" do
    assert {:error, message} =
             Restore.run("/nonexistent/staged.sql", %{filename: "gone.sql", session: "fp-gone"})

    assert message =~ "no longer available"
    assert [start] = rows("write", "database restore from gone.sql")
    assert start.caller == "admin:fp-gone"
    assert [finish] = rows("outcome", "database restore from gone.sql")
    assert finish.reason =~ "no longer available"
  end

  # PostgreSQL text cannot hold a NUL byte, so this restore's first row
  # genuinely cannot be written — and the restore must not run.
  test "a restore whose first row cannot be written does not run" do
    path = staged("SELECT 1;")

    log =
      capture_log([level: :error], fn ->
        assert {:error, message} =
                 Restore.run(path, %{filename: "bad\0name.sql", session: "fp-unrecorded"})

        assert message =~ "could not be recorded"
      end)

    assert log =~ "Audit row lost"
    refute File.exists?(path), "the refused file was kept"
    assert rows("outcome", "fp-unrecorded") == []
  end
end
