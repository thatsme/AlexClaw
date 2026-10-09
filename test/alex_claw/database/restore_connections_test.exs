defmodule AlexClaw.Database.RestoreConnectionsTest do
  @moduledoc """
  Database connections travel in the full data export like any other table,
  their passwords as references only (reports/SQL_READ_PREMISES.md §2 item
  8). A restore may bring a connection only if this installation holds its
  secret, as for a step or a resource (`RestoreKeepsSecurityTest`): otherwise
  a file could point a connection at a secret it names but does not own.
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
        host: "erp.invalid",
        port: 5432,
        database: "erp",
        username: "reader",
        tls_mode: "verify_full",
        password: "restore-Password-1"
      })

    conn
  end

  test "the export carries the connection, never its password" do
    conn = connection()
    text = Jason.encode!(export())

    assert text =~ conn.name
    refute text =~ "restore-Password-1"
  end

  test "a file whose connection references a secret this installation does not hold is refused" do
    conn = connection()
    %{"password" => %{"secret" => name}} = conn.credentials
    data = export()
    Repo.query!("DELETE FROM secrets WHERE name = $1", [name])

    assert {:error, message} = Restore.load(data)
    assert message =~ name
  end

  test "a file whose connections reference held secrets restores them" do
    conn = connection()
    data = export()

    assert {:ok, _message} = Restore.load(data)
    assert {:ok, restored} = Connections.get_by_name(conn.name)
    assert restored.credentials == conn.credentials
  end
end
