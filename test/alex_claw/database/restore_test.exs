defmodule AlexClaw.Database.RestoreTest do
  @moduledoc """
  A restore loads data, never SQL: an export round-trips exactly, the audit
  log and the sign-ins are never touched, and a file that disagrees with the
  live schema in any way changes nothing.

  The suite runs as the application role, so every restore here is one the
  application's own privileges allow — the same as in production.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias AlexClaw.Auth.{AdminSession, AuditEntry, AuditLog, Elevation, Sessions}
  alias AlexClaw.Database.{DataExport, DataSet, Restore}
  alias AlexClaw.Dispatcher.AuthCommands
  alias AlexClaw.{Message, RecordingGateway, Workflows}

  defp export do
    ""
    |> DataExport.write(fn data, acc -> [acc, data] end)
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end

  defp vector(value), do: "[" <> Enum.map_join(1..768, ",", fn _ -> value end) <> "]"

  # Rows in the tables whose types are hardest to round-trip: a foreign-key
  # chain, a self-referencing parent, pgvector, JSONB and timestamps.
  defp fixtures do
    {:ok, workflow} = Workflows.create_workflow(%{name: "restore-probe"})

    {:ok, _step} =
      Workflows.add_step(workflow, %{name: "s1", skill: "rss_collector", config: %{"k" => [1, 2]}})

    {:ok, _} = AlexClaw.Config.set("restore.probe", "original")

    %{rows: [[parent]]} =
      Repo.query!(
        "INSERT INTO memories (kind, content, embedding, metadata, inserted_at, updated_at) " <>
          "VALUES ('fact', 'parent', $1::text::vector, '{\"a\": {\"b\": 1}}', now(), now()) RETURNING id",
        [vector("0.5")]
      )

    Repo.query!(
      "INSERT INTO memories (kind, content, parent_id, inserted_at, updated_at) VALUES ('fact', 'child', $1, now(), now())",
      [parent]
    )

    workflow
  end

  describe "a round trip" do
    test "restores exactly what was exported" do
      fixtures()
      original = export()

      {:ok, _} = AlexClaw.Config.set("restore.probe", "changed")
      {:ok, _} = Workflows.create_workflow(%{name: "made after the export"})
      Repo.query!("DELETE FROM memories WHERE content = 'child'")

      assert {:ok, message} = Restore.load(original)
      assert message =~ "Restore completed"
      assert export()["tables"] == original["tables"]
    end

    test "never touches the audit log or the sign-ins" do
      fixtures()
      original = export()

      :ok = AuditLog.record_admin_write("fp-restore", "restore: written after the export")
      sid = Elevation.new_sid()
      :ok = Sessions.open(sid)

      {:ok, _} = Restore.load(original)

      assert Repo.exists?(
               from(e in AuditEntry, where: e.reason == "restore: written after the export")
             )

      assert Sessions.valid?(sid)
      assert Repo.aggregate(AdminSession, :count) >= 1
    end

    test "sets every sequence past the restored rows" do
      fixtures()
      original = export()
      {:ok, _} = Restore.load(original)

      max =
        original["tables"]["workflows"]["rows"]
        |> Enum.map(&String.to_integer(hd(&1)))
        |> Enum.max()

      {:ok, next} = Workflows.create_workflow(%{name: "after the restore"})

      assert next.id > max
    end

    # Values are bound, never interpolated: text that looks like SQL is data.
    test "a value that looks like SQL is stored as text" do
      {:ok, _} = AlexClaw.Config.set("restore.injection", "x'); DROP TABLE settings; --")
      original = export()

      {:ok, _} = Restore.load(original)

      assert AlexClaw.Config.get("restore.injection") == "x'); DROP TABLE settings; --"
      assert Repo.aggregate(AlexClaw.Config.Setting, :count) > 0
    end
  end

  describe "a file that does not fit changes nothing" do
    setup do
      fixtures()
      {:ok, original: export()}
    end

    defp unchanged!(original), do: assert(export()["tables"] == original["tables"])

    test "one holding the audit log", %{original: original} do
      bad = put_in(original, ["tables", "auth_audit_log"], %{"columns" => [], "rows" => []})
      assert {:error, message} = Restore.load(bad)
      assert message =~ "auth_audit_log"
      unchanged!(original)
    end

    test "one holding a table this database does not have", %{original: original} do
      bad = put_in(original, ["tables", "not_a_table"], %{"columns" => [], "rows" => []})
      assert {:error, message} = Restore.load(bad)
      assert message =~ "not_a_table"
      unchanged!(original)
    end

    test "one whose columns differ from this database's", %{original: original} do
      bad = update_in(original, ["tables", "settings", "columns"], &Enum.reverse/1)
      assert {:error, message} = Restore.load(bad)
      assert message =~ "columns of settings"
      unchanged!(original)
    end

    test "one made on another schema version", %{original: original} do
      assert {:error, message} = Restore.load(%{original | "schema" => 1})
      assert message =~ "schema"
      unchanged!(original)
    end

    test "one that is not an export at all", %{original: original} do
      assert {:error, _} = Restore.load(%{"hello" => "world"})
      assert {:error, _} = Restore.load(%{original | "format" => "pg_dump"})
      assert {:error, _} = Restore.load("DROP TABLE settings")
      unchanged!(original)
    end

    test "one with a value that is not text", %{original: original} do
      bad =
        update_in(original, ["tables", "settings", "rows"], fn [row | rest] ->
          [[1 | tl(row)] | rest]
        end)

      assert {:error, message} = Restore.load(bad)
      assert message =~ "settings holds a row"
      unchanged!(original)
    end

    # Checked by the database, part-way through the transaction: everything
    # already written is rolled back.
    test "one with a value its column refuses", %{original: original} do
      bad =
        update_in(original, ["tables", "workflows", "rows"], fn [row | rest] ->
          [List.replace_at(row, 0, "not a number") | rest]
        end)

      assert {:error, message} = Restore.load(bad)
      assert message =~ "workflows holds a value this database refuses"
      unchanged!(original)
    end
  end

  describe "run/2" do
    defp staged(data) do
      path = Path.join(System.tmp_dir!(), "restore-#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(data))
      {:ok, staged} = Restore.stage(path)
      File.rm(path)
      staged
    end

    defp rows(decision, fragment) do
      Repo.all(
        from(e in AuditEntry, where: e.decision == ^decision and like(e.reason, ^"%#{fragment}%"))
      )
    end

    test "restores, audits before and after, and discards the file" do
      fixtures()
      path = staged(export())

      assert {:ok, _} = Restore.run(path, %{filename: "data.json", session: "fp-run"})

      refute File.exists?(path)
      assert [start] = rows("write", "database restore from data.json")
      assert start.caller == "admin:fp-run"
      assert [finish] = rows("outcome", "database restore from data.json")
      assert finish.reason =~ "Restore completed"
    end

    test "a file that is not JSON is refused, and says so in the outcome row" do
      path = Path.join(System.tmp_dir!(), "restore-#{System.unique_integer([:positive])}.json")
      File.write!(path, "DROP TABLE settings;")

      assert {:error, message} = Restore.run(path, %{filename: "evil.json", session: "fp-evil"})
      assert message =~ "not valid JSON"
      assert [finish] = rows("outcome", "database restore from evil.json")
      assert finish.reason =~ "not valid JSON"
    end

    test "a restore whose first row cannot be written does not run" do
      fixtures()
      original = export()
      path = staged(original)

      capture_log([level: :error], fn ->
        assert {:error, message} = Restore.run(path, %{filename: "bad\0.json", session: "fp-nul"})
        assert message =~ "could not be recorded"
      end)

      refute File.exists?(path)
      assert export()["tables"] == original["tables"]
    end

    test "a restore challenge answered on a gateway runs the restore" do
      RecordingGateway.install()
      fixtures()
      path = staged(export())

      AuthCommands.execute_2fa_action(
        %{type: :database_restore, path: path, filename: "pending.json", session: "fp-pending"},
        %Message{
          text: "",
          chat_id: "1",
          from: "t",
          timestamp: DateTime.utc_now(),
          raw: %{},
          gateway: :test
        }
      )

      assert Enum.any?(RecordingGateway.sent(), &(&1 =~ "Restore completed"))
    end
  end

  test "the exported tables leave out the audit log, the sign-ins and the migrator's" do
    assert Enum.sort(DataSet.excluded()) == ~w(admin_sessions auth_audit_log schema_migrations)
    refute Enum.any?(DataSet.excluded(), &(&1 in DataSet.tables()))
    assert Map.keys(export()["tables"]) |> Enum.sort() == Enum.sort(DataSet.tables())
  end

  # Nothing in the application runs an SQL file: psql obeys meta-commands, and
  # a restore is data.
  test "nothing in lib/ invokes psql" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,exs}"),
          File.read!(path) =~ ~r/["'`]psql["'`\s]/,
          do: path

    assert offenders == []
  end
end
