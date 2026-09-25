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
  alias AlexClaw.Config.Crypto
  alias AlexClaw.Database.{DataExport, DataSet, Restore}
  alias AlexClaw.{LLM, SandboxCleanup, Workflows}

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
    # LLM providers still keep their credentials encrypted in the row. Since
    # 0.4.0 (S4a) a step's credential is a reference to OpenBao: an export
    # carries the reference, a restore puts it back, and OpenBao — which a
    # database restore does not touch — still holds the value.
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

    test "are exported as stored (encrypted, or a reference) and restored usable" do
      p = provider(%{api_key: "sk-plain-key", headers: %{"x-api-key" => "hdr-secret"}})
      step = telegram_step(%{"bot_token" => "123:bot-secret", "chat_id" => "42"})
      original = export()
      text = Jason.encode!(original)

      for secret <- ["sk-plain-key", "hdr-secret", "123:bot-secret"], do: refute(text =~ secret)
      assert Crypto.encrypted?(exported(original, "llm_providers", p.id, "api_key"))
      headers = Jason.decode!(exported(original, "llm_providers", p.id, "headers"))
      assert Map.keys(headers) == ["x-api-key"], "header names stay readable"
      assert Crypto.encrypted?(headers["x-api-key"])

      config = Jason.decode!(exported(original, "workflow_steps", step.id, "config"))
      assert %{"secret" => name} = config["bot_token"]
      assert config["chat_id"] == "42"

      Repo.query!("UPDATE llm_providers SET api_key = 'changed'")
      assert {:ok, _} = Restore.load(original)

      restored = Repo.get!(AlexClaw.LLM.Provider, p.id)
      assert restored.api_key == "sk-plain-key"
      assert restored.headers == %{"x-api-key" => "hdr-secret"}

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

    test "that are nil or empty stay so" do
      none = provider(%{api_key: nil})
      # Ecto casts "" to nil, so the empty string is written directly.
      empty = provider(%{api_key: nil})
      Repo.query!("UPDATE llm_providers SET api_key = '' WHERE id = $1", [empty.id])
      # 0.3.54: a telegram_notify step without its own token is saved only when
      # Telegram is configured.
      insert_setting("telegram.enabled", "true", type: "boolean", category: "telegram")
      insert_setting("telegram.bot_token", "test-token", type: "string", category: "telegram")
      step = telegram_step(%{"bot_token" => "", "chat_id" => "1"})
      original = export()

      assert exported(original, "llm_providers", none.id, "api_key") == nil
      assert exported(original, "llm_providers", empty.id, "api_key") == ""

      assert Jason.decode!(exported(original, "workflow_steps", step.id, "config"))["bot_token"] ==
               ""

      assert {:ok, _} = Restore.load(original)
      assert Repo.get!(AlexClaw.LLM.Provider, none.id).api_key == nil
      assert Repo.get!(AlexClaw.LLM.Provider, empty.id).api_key == ""
    end

    # The restore runs under a different SECRET_KEY_BASE than the export did.
    test "encrypted under another key are refused, and nothing changes" do
      p = provider(%{api_key: "sk-original"})
      original = export()

      {:ok, foreign} =
        Crypto.encrypt_with(Crypto.key_for(String.duplicate("another-key-base", 4)), "sk-foreign")

      bad = replace_value(original, "llm_providers", p.id, "api_key", foreign)

      assert {:error, message} = Restore.load(bad)
      assert message =~ "llm_providers"
      assert message =~ "SECRET_KEY_BASE"
      assert Repo.get!(AlexClaw.LLM.Provider, p.id).api_key == "sk-original"
    end

    # Settings are exported as stored, encrypted; a file from another key
    # would otherwise restore a TOTP secret nothing can decrypt.
    test "an encrypted setting from another key is refused" do
      {:ok, _} = AlexClaw.Config.set("restore.sealed", "mine", sensitive: true)
      original = export()

      {:ok, foreign} =
        Crypto.encrypt_with(Crypto.key_for(String.duplicate("another-key-base", 4)), "theirs")

      bad =
        update_in(original, ["tables", "settings"], fn %{"columns" => names, "rows" => rows} = e ->
          key = Enum.find_index(names, &(&1 == "key"))
          value = Enum.find_index(names, &(&1 == "value"))

          rows =
            Enum.map(rows, fn row ->
              if Enum.at(row, key) == "restore.sealed",
                do: List.replace_at(row, value, foreign),
                else: row
            end)

          %{e | "rows" => rows}
        end)

      assert {:error, message} = Restore.load(bad)
      assert message =~ "settings"
      assert AlexClaw.Config.get("restore.sealed") == "mine"
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

  # Each sequence a restore may set, with its value now: {sequence, last_value, is_called}.
  defp sequences do
    restored = DataSet.tables()

    %{rows: serials} =
      Repo.query!("""
      SELECT table_name, column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND column_default LIKE 'nextval(%'
      """)

    for [table, column] <- serials, table in restored do
      %{rows: [[sequence]]} =
        Repo.query!("SELECT pg_get_serial_sequence($1, $2)", ["public." <> table, column])

      %{rows: [[value, called]]} = Repo.query!("SELECT last_value, is_called FROM #{sequence}")
      {sequence, value, called}
    end
  end

  defp put_back({sequence, value, called}),
    do: Repo.query!("SELECT setval($1::text::regclass, $2, $3)", [sequence, value, called])

  # A file 0.3.34 wrote (test/fixtures/exports/v0.3.34.json, produced by the
  # 0.3.34 code under the test SECRET_KEY_BASE) restores here unchanged: no
  # release may write an export the next cannot restore. The fixture pins the
  # schema version; a release that adds a migration must decide what a
  # restore of the previous release's exports does, and change this test.
  defp json_or_text("{" <> _ = value), do: Jason.decode!(value)
  defp json_or_text(value), do: value

  describe "an export written by 0.3.34" do
    @v0_3_34 Path.expand("../../fixtures/exports/v0.3.34.json", __DIR__)

    # The restore sets each sequence to the file's highest id, and a sequence is
    # not rolled back with the sandbox: after this test settings_id_seq stayed at
    # the fixture's 79 while the seeded rows went past it, and the next insert
    # anywhere in the suite collided. Every sequence is put back as it was.
    setup do
      kept = sequences()
      on_exit(fn -> SandboxCleanup.run(fn -> Enum.each(kept, &put_back/1) end) end)
    end

    test "restores, with its credentials readable and encrypted at rest as they were" do
      file = @v0_3_34 |> File.read!() |> Jason.decode!()

      assert {:ok, _} = Restore.load(file)

      provider = Repo.get_by!(AlexClaw.LLM.Provider, name: "fixture-provider")
      assert provider.api_key == "sk-fixture"
      assert provider.headers == %{"x-api-key" => "hdr-fixture"}

      steps = Map.new(Repo.all(AlexClaw.Workflows.WorkflowStep), &{&1.name, &1.config})
      assert steps["tg"]["bot_token"] == "123:fixture"
      assert steps["api"]["headers"] == %{"authorization" => "Bearer fixture"}
      setting = Repo.get_by!(AlexClaw.Config.Setting, key: "fixture.secret")
      assert Crypto.decrypt(setting.value) == {:ok, "setting-secret"}

      %{rows: [[stored_key]]} =
        Repo.query!("SELECT api_key FROM llm_providers WHERE name = 'fixture-provider'")

      assert Crypto.encrypted?(stored_key), "restored as stored, not in plain text"
      # The same ciphertext, byte for byte; JSON compared decoded, since
      # PostgreSQL spaces its jsonb text form.
      [restored] = export()["tables"]["llm_providers"]["rows"]
      [original] = file["tables"]["llm_providers"]["rows"]
      assert Enum.map(restored, &json_or_text/1) == Enum.map(original, &json_or_text/1)
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
