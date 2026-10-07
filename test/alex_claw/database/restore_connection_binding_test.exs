defmodule AlexClaw.Database.RestoreConnectionBindingTest do
  @moduledoc """
  A restore brings a connection only if its server is the one its secret was
  entered for (reports/SQLREAD_ATTACKER_REVIEW.md H1). An older backup, or an
  edited file, naming another host for a connection whose secret this
  installation holds is refused before anything is written: the file never
  decides where a password is sent.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Connections
  alias AlexClaw.Database.{DataExport, Restore}

  defp export do
    ""
    |> DataExport.write(fn data, acc -> [acc, data] end)
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end

  defp connection do
    {:ok, conn} =
      Connections.create_connection(%{
        name: "restored_#{System.unique_integer([:positive])}",
        host: "erp-a.invalid",
        port: 5432,
        database: "erp",
        username: "reader",
        tls_mode: "verify_full",
        password: "server-A-Password"
      })

    conn
  end

  # The export's db_connections rows, with `column` set to `value` on every one.
  defp edited(data, column, value) do
    update_in(data, ["tables", "db_connections"], fn table ->
      index = Enum.find_index(table["columns"], &(&1 == column))
      %{table | "rows" => Enum.map(table["rows"], &List.replace_at(&1, index, value))}
    end)
  end

  test "an older backup naming the server the password was not entered for is refused" do
    conn = connection()
    %{"password" => %{"secret" => old_secret}} = conn.credentials
    older = export()

    {:ok, _} =
      Connections.update_connection(conn, %{host: "erp-b.invalid", password: "server-B-Password"})

    # The new password is a secret of its own and the old one is gone (F1):
    # the older file names a secret this installation no longer holds.
    assert {:error, message} = Restore.load(older)
    assert message =~ old_secret
    refute message =~ "server-B-Password"
    assert {:ok, %{host: "erp-b.invalid"}} = Connections.get_by_name(conn.name)
  end

  for {column, value} <- [
        {"host", "attacker.invalid"},
        {"port", "6543"},
        {"database", "other"},
        {"username", "someone_else"},
        {"tls_mode", "disable"}
      ] do
    test "a file whose connection's #{column} was edited is refused" do
      conn = connection()
      data = edited(export(), unquote(column), unquote(value))

      assert {:error, message} = Restore.load(data)
      assert message =~ conn.name
    end
  end

  test "a file whose connections match their secrets' servers restores them" do
    conn = connection()
    assert {:ok, _} = Restore.load(export())
    assert {:ok, restored} = Connections.get_by_name(conn.name)
    assert restored.host == conn.host
  end
end
