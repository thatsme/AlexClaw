defmodule AlexClaw.Database.RestoreTest do
  @moduledoc """
  Restore from the admin UI is disabled until 0.3.34. Every path that reaches
  `Restore.run/2` is refused, audited as refused, and leaves no staged file —
  including a restore challenge raised before the upgrade and answered after it.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.AuditEntry
  alias AlexClaw.Database.Restore
  alias AlexClaw.Dispatcher.AuthCommands
  alias AlexClaw.{Message, RecordingGateway}

  defp staged_file do
    path =
      Path.join(
        System.tmp_dir!(),
        "alexclaw-restore-test-#{System.unique_integer([:positive])}.sql"
      )

    File.write!(path, "SELECT 1;")
    path
  end

  defp refusals(fragment) do
    Repo.all(
      from(e in AuditEntry, where: e.decision == "deny" and like(e.reason, ^"%#{fragment}%"))
    )
  end

  test "run/2 refuses, records the refusal, and discards the file" do
    path = staged_file()

    assert Restore.run(path, %{filename: "dump.sql", session: "fp-refused"}) ==
             {:error, Restore.refusal()}

    refute File.exists?(path)
    assert [row] = refusals("database restore from dump.sql")
    assert row.caller == "admin:fp-refused"
    assert row.reason =~ "disabled"
  end

  test "the refusal says restore is an operator procedure" do
    assert Restore.refusal() =~ "operator procedure"
  end

  test "a restore challenge answered on a gateway after the upgrade is refused" do
    RecordingGateway.install()
    path = staged_file()

    AuthCommands.execute_2fa_action(
      %{type: :database_restore, path: path, filename: "pending.sql", session: "fp-pending"},
      %Message{
        text: "",
        chat_id: "1",
        from: "t",
        timestamp: DateTime.utc_now(),
        raw: %{},
        gateway: :test
      }
    )

    refute File.exists?(path)
    assert [_row] = refusals("database restore from pending.sql")
    assert Enum.any?(RecordingGateway.sent(), &(&1 =~ "operator procedure"))
  end

  test "discard/1 tolerates a file that is already gone" do
    assert Restore.discard("/nonexistent/staged.sql") == :ok
  end
end
