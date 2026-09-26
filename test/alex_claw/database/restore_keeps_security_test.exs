defmodule AlexClaw.Database.RestoreKeepsSecurityTest do
  @moduledoc """
  A restore replaces data, never how this installation is protected (S9 fix
  review, ruling on F2 and F3; THREAT_MODEL P4, P5).

  Kept from this installation, whatever the file holds, like the admin's
  identity (S8 H4):
  - the secret catalogue (`secrets`): where each secret may be sent. A file
    that rebinds a secret to another host would have it sent there. A step
    or resource in the file may reference only a secret this installation
    holds.
  - the login protection settings (`auth.rate_limit.*`,
    `auth.trust_proxy_headers`) and the gateway owners (the owner chats and
    users);
  - the authorisation policies (`auth_policies`).

  After a restore, every other admin session is signed out and the cached
  settings and policies are read again, so nothing still acts on what the
  data was before.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{Elevation, Policies, Policy, Sessions}
  alias AlexClaw.{Config, Secrets, Workflows}
  alias AlexClaw.Database.{DataExport, DataSet, Restore}

  defp export do
    ""
    |> DataExport.write(fn data, acc -> [acc, data] end)
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end

  # A crafted file, or one exported before these tables were left out: the
  # table as this database holds it, every value as text.
  defp with_table(data, table) do
    columns = Enum.map(DataSet.columns(table), &elem(&1, 0))
    fields = Enum.map_join(columns, ", ", &(DataSet.quote_name(&1) <> "::text"))
    %{rows: rows} = Repo.query!("SELECT #{fields} FROM #{DataSet.quote_name(table)}")
    put_in(data, ["tables", table], %{"columns" => columns, "rows" => rows})
  end

  defp column_name([name | _]), do: name
  defp column_name(%{"name" => name}), do: name
  defp column_name(name) when is_binary(name), do: name

  defp names(data, table), do: Enum.map(data["tables"][table]["columns"], &column_name/1)

  # The file's rows of `table`, each passed through `fun` as a column => value map.
  defp map_rows(data, table, fun) do
    columns = names(data, table)

    update_in(data, ["tables", table, "rows"], fn rows ->
      Enum.map(rows, fn row ->
        values = columns |> Enum.zip(row) |> Map.new() |> fun.()
        Enum.map(columns, &Map.get(values, &1))
      end)
    end)
  end

  defp with_setting(data, key, value) do
    map_rows(data, "settings", fn
      %{"key" => ^key} = row -> %{row | "value" => value}
      row -> row
    end)
  end

  defp live_setting(key) do
    %{rows: rows} = Repo.query!("SELECT value FROM settings WHERE key = $1", [key])
    rows
  end

  describe "the secret catalogue" do
    test "a file cannot rebind a secret to another host" do
      name = "restore_bind_#{System.unique_integer([:positive])}"
      {:ok, _} = Secrets.define(%{name: name, kind: "api_token", binding: ["host:good.example"]})

      data =
        export()
        |> with_table("secrets")
        |> map_rows("secrets", fn
          %{"name" => ^name} = row -> %{row | "binding" => "{host:attacker.example}"}
          row -> row
        end)

      assert {:ok, _message} = Restore.load(data)
      assert Secrets.get(name).binding == ["host:good.example"]
    end

    test "a file referencing a secret this installation does not hold is refused" do
      {:ok, wf} = Workflows.create_workflow(%{name: "restore-ref-#{System.unique_integer()}"})

      {:ok, step} =
        Workflows.add_step(wf, %{
          name: "Call",
          skill: "api_request",
          config: %{"url" => "https://api.example.com/x", "headers" => %{"X-Key" => "v-123456"}}
        })

      %{"secret" => name} = step.config["headers"]["X-Key"]
      data = export()
      Repo.query!("DELETE FROM secrets WHERE name = $1", [name])

      assert {:error, message} = Restore.load(data)
      assert message =~ name
    end
  end

  test "login protection and gateway owners are kept" do
    live = [
      {"auth.rate_limit.max_attempts", "5", "integer"},
      {"auth.trust_proxy_headers", "false", "boolean"},
      {"telegram.owner_user_id", "4242", "string"},
      {"discord.owner_user_id", "4343", "string"}
    ]

    for {key, value, type} <- live, do: Config.set(key, value, type: type, category: "auth")

    data =
      export()
      |> with_setting("auth.rate_limit.max_attempts", "100000")
      |> with_setting("auth.trust_proxy_headers", "true")
      |> with_setting("telegram.owner_user_id", "666")
      |> with_setting("discord.owner_user_id", "667")

    assert {:ok, _message} = Restore.load(data)

    for {key, value, _type} <- live, do: assert(live_setting(key) == [[value]], key)
  end

  test "the authorisation policies are kept" do
    {:ok, policy} =
      Policies.create_policy(%{
        name: "kept-#{System.unique_integer([:positive])}",
        rule_type: "rate_limit",
        config: %{"max" => 1}
      })

    data =
      export() |> with_table("auth_policies") |> put_in(["tables", "auth_policies", "rows"], [])

    assert {:ok, _message} = Restore.load(data)
    assert Repo.get(Policy, policy.id)
  end

  describe "after a restore" do
    setup do
      path = Path.join(System.tmp_dir!(), "restore-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    defp staged(path, data) do
      File.write!(path, Jason.encode!(data))
      path
    end

    test "other admin sessions are signed out, the restoring one kept", %{path: path} do
      restoring = "sid-restoring-#{System.unique_integer([:positive])}"
      other = "sid-other-#{System.unique_integer([:positive])}"
      :ok = Sessions.open(restoring)
      :ok = Sessions.open(other)
      data = export()

      assert {:ok, _} =
               Restore.run(staged(path, data), %{
                 filename: "backup.json",
                 session: Elevation.fingerprint(restoring)
               })

      assert Sessions.valid?(restoring)
      refute Sessions.valid?(other)
    end

    test "the cached settings are read again", %{path: path} do
      data = export()
      Config.set("custom.restore_probe", "before", type: "string", category: "custom")
      assert Config.get("custom.restore_probe") == "before"

      assert {:ok, _} = Restore.run(staged(path, data), %{filename: "b.json", session: "x"})

      assert Config.get("custom.restore_probe") == nil
    end
  end
end
