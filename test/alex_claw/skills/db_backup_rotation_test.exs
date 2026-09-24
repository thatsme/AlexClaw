defmodule AlexClaw.Skills.DbBackupRotationTest do
  @moduledoc """
  Rotation counts what it deleted, not what it tried to delete
  (reports/SECOND_ROUND_SEAMS.md §6; 0.3.53).

  `db_backup` ignored `File.rm/1`'s result (:180) and reported "rotated N old
  backups" with N the attempts. The rotation is now its own function,
  `DbBackup.rotate(dir, keep)`, so it can be tested without a dump:
      {:ok, %{deleted: [path], failed: [{path, reason}]}}
  The skill's message reports `length(deleted)`, and names any failure.

  A failed delete is forced portably: a DIRECTORY with a backup-shaped name
  is picked for deletion like a file, and `File.rm/1` refuses a directory
  even for root (the test container runs as uid 0, so permissions would not).
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Skills.DbBackup

  setup do
    dir = Path.join(System.tmp_dir!(), "backup_rotation_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp backup(dir, stamp) do
    path = Path.join(dir, "alexclaw_backup_#{stamp}.sql.gz")
    File.write!(path, "x")
    path
  end

  test "keeps the newest, deletes the rest, and says exactly which", %{dir: dir} do
    oldest = backup(dir, "20260901_060000")
    older = backup(dir, "20260910_060000")
    kept1 = backup(dir, "20260920_060000")
    kept2 = backup(dir, "20260924_060000")

    assert {:ok, %{deleted: deleted, failed: []}} = DbBackup.rotate(dir, 2)

    assert Enum.sort(deleted) == Enum.sort([oldest, older])
    assert File.exists?(kept1) and File.exists?(kept2)
    refute File.exists?(oldest) or File.exists?(older)
  end

  test "a delete that fails is reported, not counted", %{dir: dir} do
    stuck = Path.join(dir, "alexclaw_backup_00000000_000000.sql.gz")
    File.mkdir_p!(stuck)
    old = backup(dir, "20260901_060000")
    backup(dir, "20260924_060000")

    assert {:ok, %{deleted: deleted, failed: failed}} = DbBackup.rotate(dir, 1)

    assert deleted == [old]
    assert [{^stuck, _reason}] = failed
  end

  test "files that are not backups are never touched", %{dir: dir} do
    other = Path.join(dir, "notes.txt")
    File.write!(other, "keep me")
    backup(dir, "20260901_060000")
    backup(dir, "20260924_060000")

    DbBackup.rotate(dir, 1)
    assert File.exists?(other)
  end

  test "nothing to rotate is an empty result" do
    dir = Path.join(System.tmp_dir!(), "empty_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, %{deleted: [], failed: []}} = DbBackup.rotate(dir, 3)
  end
end
