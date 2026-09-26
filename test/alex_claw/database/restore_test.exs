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
  alias AlexClaw.{LLM, Workflows}

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
      Workflows.add_step(workflow, %{
        name: "s1",
        skill: "receive_from_workflow",
        config: %{"allowed_nodes" => ["n1@host", "n2@host"]}
      })

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

  describe "credentials stored outside the settings" do
    # Since 0.4.0 a step's credential (S4a) and an LLM provider's (S7) are
    # references to OpenBao: an export carries the reference, a restore puts it
    # back, and OpenBao — which a database restore does not touch — still
    # holds the value.
    @describetag :vault

    defp provider(attrs) do
      {:ok, provider} =
        LLM.create_provider(
          Map.merge(
            %{
              name: "sealed-#{System.unique_integer([:positive])}",
              type: "openai_compatible",
              tier: "light",
              model: "m"
            },
            attrs
          )
        )

      provider
    end

    defp exported(export, table, id, column) do
      %{"columns" => names, "rows" => rows} = export["tables"][table]
      index = Enum.find_index(names, &(&1 == column))
      row = Enum.find(rows, &(hd(&1) == to_string(id)))
      Enum.at(row, index)
    end

    defp telegram_step(config) do
      workflow = fixtures()

      {:ok, step} =
        Workflows.add_step(workflow, %{name: "tg", skill: "telegram_notify", config: config})

      step
    end

    test "are exported as references and restored usable" do
      p =
        provider(%{
          host: "https://llm.example.com",
          api_key: "sk-plain-key",
          headers: %{"x-api-key" => "hdr-secret"}
        })

      step = telegram_step(%{"bot_token" => "123:bot-secret", "chat_id" => "42"})
      original = export()
      text = Jason.encode!(original)

      for secret <- ["sk-plain-key", "hdr-secret", "123:bot-secret"], do: refute(text =~ secret)

      credentials = Jason.decode!(exported(original, "llm_providers", p.id, "credentials"))
      assert %{"secret" => key_name} = credentials["api_key"]
      assert Map.keys(credentials["headers"]) == ["x-api-key"], "header names stay readable"

      config = Jason.decode!(exported(original, "workflow_steps", step.id, "config"))
      assert %{"secret" => name} = config["bot_token"]
      assert config["chat_id"] == "42"

      Repo.query!("UPDATE llm_providers SET credentials = '{}'")
      assert {:ok, _} = Restore.load(original)

      restored = Repo.get!(AlexClaw.LLM.Provider, p.id)
      assert AlexClaw.LLM.Client.resolve_api_key(restored) == "sk-plain-key"
      assert %{"api_key" => %{"secret" => ^key_name}} = restored.credentials

      assert %{"secret" => ^name} =
               Repo.get!(AlexClaw.Workflows.WorkflowStep, step.id).config["bot_token"]

      assert {:ok, "123:bot-secret"} =
               AlexClaw.Secrets.resolve(name,
                 for: AlexClaw.Config.secret_binding("telegram.bot_token")
               )
    end

    test "include an API Request step's credential header, as a reference" do
      workflow = fixtures()

      {:ok, step} =
        Workflows.add_step(workflow, %{
          name: "api",
          skill: "api_request",
          config: %{
            "url" => "https://example.com",
            "headers" => %{"authorization" => "Bearer api-secret"}
          }
        })

      original = export()
      refute Jason.encode!(original) =~ "api-secret"

      config = Jason.decode!(exported(original, "workflow_steps", step.id, "config"))
      assert %{"secret" => name} = config["headers"]["authorization"]
      assert config["url"] == "https://example.com"

      assert {:ok, _} = Restore.load(original)

      assert {:ok, "Bearer api-secret"} = AlexClaw.Secrets.resolve(name, for: "host:example.com")
    end

    # A provider's key is a reference or nothing since 0.4.0 (S7); the empty
    # case left with the encrypted column.
    test "that are nil or empty stay so" do
      # 0.3.54: a telegram_notify step without its own token is saved only when
      # Telegram is configured.
      insert_setting("telegram.enabled", "true", type: "boolean", category: "telegram")
      insert_setting("telegram.bot_token", "test-token", type: "string", category: "telegram")
      step = telegram_step(%{"bot_token" => "", "chat_id" => "1"})
      original = export()

      assert Jason.decode!(exported(original, "workflow_steps", step.id, "config"))["bot_token"] ==
               ""

      assert {:ok, _} = Restore.load(original)

      assert Repo.get!(AlexClaw.Workflows.WorkflowStep, step.id).config["bot_token"] == ""
    end

    # There is no ciphertext left to tamper with in a step. What can be wrong
    # now is a reference naming a secret that does not exist: a restore that
    # accepted it would leave a step that fails at 6 a.m.
    test "a step reference to a secret that does not exist is refused, and nothing changes" do
      step = telegram_step(%{"bot_token" => "t", "chat_id" => "1"})
      original = export()
      config = Jason.decode!(exported(original, "workflow_steps", step.id, "config"))
      tampered = Jason.encode!(%{config | "bot_token" => %{"secret" => "no_such_secret_xyz"}})
      bad = replace_value(original, "workflow_steps", step.id, "config", tampered)

      assert {:error, message} = Restore.load(bad)
      assert message =~ "workflow_steps"
      assert message =~ "no_such_secret_xyz"

      assert %{"secret" => _} =
               Repo.get!(AlexClaw.Workflows.WorkflowStep, step.id).config["bot_token"]
    end

    defp replace_value(export, table, id, column, value) do
      update_in(export, ["tables", table], fn %{"columns" => names, "rows" => rows} = entry ->
        index = Enum.find_index(names, &(&1 == column))

        key = to_string(id)

        rows =
          Enum.map(rows, fn
            [^key | _] = row -> List.replace_at(row, index, value)
            row -> row
          end)

        %{entry | "rows" => rows}
      end)
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

    test "one in format version 1, which no release wrote", %{original: original} do
      assert {:error, message} = Restore.load(%{original | "version" => 1})
      assert message =~ "version"
      unchanged!(original)
    end

    # A file from a NEWER schema cannot be restored: this database does not
    # have what that release added. (An older one can, when the database only
    # added nullable columns since — "an export from an older schema".)
    test "one made on a newer schema version", %{original: original} do
      assert {:error, message} = Restore.load(%{original | "schema" => 99_991_231_235_959})
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

  # No release may write an export the next cannot restore. Most migrations
  # only ADD: a new nullable column (0.3.55: workflow_runs.definition). A file
  # from before such a migration restores, the added columns as null. A file
  # that lacks a column the database requires, or has one it no longer has,
  # is refused naming it — a migration that is not additive decides then.
  describe "an export from an older schema" do
    setup do
      workflow = fixtures()
      {:ok, _run} = Workflows.create_run(workflow)
      {:ok, original: export()}
    end

    defp drop_column(export, table, column) do
      update_in(export, ["tables", table], fn %{"columns" => names, "rows" => rows} = entry ->
        index = Enum.find_index(names, &(&1 == column))

        %{
          entry
          | "columns" => List.delete_at(names, index),
            "rows" => Enum.map(rows, &List.delete_at(&1, index))
        }
      end)
    end

    defp older(export), do: %{export | "schema" => 20_260_921_090_000}

    test "restores when the database only added nullable columns", %{original: original} do
      file = original |> drop_column("workflow_runs", "definition") |> older()

      assert {:ok, _} = Restore.load(file)
      assert [run] = Repo.all(AlexClaw.Workflows.WorkflowRun)
      assert run.definition == nil
    end

    test "is refused when a column it lacks is required, naming it", %{original: original} do
      file = original |> drop_column("workflows", "name") |> older()

      assert {:error, message} = Restore.load(file)
      assert message =~ "workflows"
      assert message =~ "name"
      unchanged!(original)
    end

    test "is refused when it has a column the database no longer has", %{original: original} do
      file =
        original
        |> update_in(["tables", "workflows"], fn %{"columns" => names, "rows" => rows} = e ->
          %{
            e
            | "columns" => names ++ ["retired_column"],
              "rows" => Enum.map(rows, &(&1 ++ ["x"]))
          }
        end)
        |> older()

      assert {:error, message} = Restore.load(file)
      assert message =~ "retired_column"
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
  end

  test "the exported tables leave out the audit log, the sign-ins, the recovery codes and the migrator's" do
    assert Enum.sort(DataSet.excluded()) ==
             ~w(admin_sessions auth_audit_log auth_recovery_codes schema_migrations)

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
