defmodule AlexClaw.ConnectionsTest do
  @moduledoc """
  Database connections, defined in the admin UI: a name, a PostgreSQL server
  (host, port, database, user) and a TLS mode chosen explicitly. The password
  is a secret in OpenBao, bound to the connection and its server
  (`ConnectionSecrets.destination/1`); the row keeps a reference
  (reports/SQL_READ_PREMISES.md §4.1).

  - Every field is required; the TLS mode has no default and is one of
    `disable`, `require`, `verify_full`.
  - The name is the binding, so it never changes.
  - Leaving the password blank on an edit keeps it. Pointing the connection
    at another server (host, port, database, user or TLS mode) with the
    password kept is refused: it must be entered again for the new server.
  - Deleting a connection deletes its secret.
  - No connection exists until an admin defines one.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.{Connections, Secrets}
  alias AlexClaw.Connections.{Connection, ConnectionSecrets}

  @password "s3cret-db-Password"

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "erp_#{System.unique_integer([:positive])}",
        host: "erp-db.example.com",
        port: 5432,
        database: "erp",
        username: "reader",
        tls_mode: "verify_full",
        password: @password
      },
      overrides
    )
  end

  defp raw_row(id) do
    %{rows: [[text]]} =
      Repo.query!("SELECT row_to_json(c)::text FROM db_connections c WHERE id = $1", [id])

    text
  end

  defp secret_name(%Connection{credentials: %{"password" => %{"secret" => name}}}), do: name

  defp errors(changeset),
    do: Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

  describe "creating a connection" do
    test "with every field: the password goes to OpenBao, bound to the connection; the row holds none" do
      assert {:ok, %Connection{} = conn} = Connections.create_connection(attrs())

      refute raw_row(conn.id) =~ @password
      name = secret_name(conn)

      assert %Secrets.Secret{kind: "database_password", binding: [binding]} = Secrets.get(name)
      assert binding == ConnectionSecrets.destination(conn)
      assert {:ok, @password} = Secrets.resolve(name, for: ConnectionSecrets.destination(conn))
    end

    test "its password resolves for no other connection" do
      {:ok, conn} = Connections.create_connection(attrs())

      assert {:error, :not_bound} =
               Secrets.resolve(secret_name(conn), for: "connection:some_other")
    end

    for field <- [:name, :host, :port, :database, :username, :tls_mode, :password] do
      test "without #{field} is refused" do
        assert {:error, changeset} =
                 Connections.create_connection(Map.delete(attrs(), unquote(field)))

        assert Map.has_key?(errors(changeset), unquote(field))
      end
    end

    test "the TLS mode has no default" do
      assert %Connection{}.tls_mode == nil
    end

    test "the TLS mode is one of disable, require, verify_full" do
      for mode <- ~w(disable require verify_full) do
        assert {:ok, _} = Connections.create_connection(attrs(%{tls_mode: mode}))
      end

      for mode <- ["verify-full", "prefer", "allow", "", "VERIFY_FULL"] do
        assert {:error, changeset} = Connections.create_connection(attrs(%{tls_mode: mode}))
        assert Map.has_key?(errors(changeset), :tls_mode), "#{inspect(mode)} was accepted"
      end
    end

    test "the name is a short lowercase identifier" do
      for bad <- ["ERP", "erp db", "erp-db", "erp:db", String.duplicate("a", 41)] do
        assert {:error, changeset} = Connections.create_connection(attrs(%{name: bad}))
        assert Map.has_key?(errors(changeset), :name), "#{inspect(bad)} was accepted"
      end
    end

    test "names are unique" do
      {:ok, conn} = Connections.create_connection(attrs())
      assert {:error, changeset} = Connections.create_connection(attrs(%{name: conn.name}))
      assert Map.has_key?(errors(changeset), :name)
    end

    test "the port is a TCP port" do
      for bad <- [0, 65_536, -1] do
        assert {:error, changeset} = Connections.create_connection(attrs(%{port: bad}))
        assert Map.has_key?(errors(changeset), :port)
      end
    end

    test "a refused save names no password in its errors" do
      assert {:error, changeset} =
               Connections.create_connection(attrs(%{tls_mode: "nonsense"}))

      refute inspect(changeset.errors) =~ @password
      refute inspect(changeset.changes) =~ @password
    end
  end

  describe "editing a connection" do
    setup do
      {:ok, conn} = Connections.create_connection(attrs())
      %{conn: conn}
    end

    test "its name cannot be changed", %{conn: conn} do
      assert {:error, changeset} = Connections.update_connection(conn, %{name: "renamed"})
      assert Map.has_key?(errors(changeset), :name)
      assert {:ok, _} = Connections.get_by_name(conn.name)
    end

    test "a blank password keeps the stored one", %{conn: conn} do
      before = Secrets.get(secret_name(conn)).rotated_at

      assert {:ok, updated} = Connections.update_connection(conn, %{password: ""})
      assert secret_name(updated) == secret_name(conn)
      assert Secrets.get(secret_name(conn)).rotated_at == before

      assert {:ok, @password} =
               Secrets.resolve(secret_name(updated), for: ConnectionSecrets.destination(updated))
    end

    test "a new password replaces it", %{conn: conn} do
      assert {:ok, updated} = Connections.update_connection(conn, %{password: "n3w-Password"})

      assert {:ok, "n3w-Password"} =
               Secrets.resolve(secret_name(updated), for: ConnectionSecrets.destination(updated))
    end

    for {field, value} <- [
          host: "other-db.example.com",
          port: 6543,
          database: "other",
          username: "someone_else",
          tls_mode: "disable"
        ] do
      test "another #{field} with the password kept is refused: it must be entered again",
           %{conn: conn} do
        assert {:error, changeset} =
                 Connections.update_connection(conn, %{unquote(field) => unquote(value)})

        assert errors(changeset)[:password] |> Enum.join() =~ "entered again"
        assert {:ok, still} = Connections.get_by_name(conn.name)
        assert Map.get(still, unquote(field)) == Map.get(conn, unquote(field))
      end

      test "another #{field} with a new password is saved", %{conn: conn} do
        assert {:ok, updated} =
                 Connections.update_connection(conn, %{
                   unquote(field) => unquote(value),
                   password: "for-the-new-server"
                 })

        assert Map.get(updated, unquote(field)) == unquote(value)

        assert {:ok, "for-the-new-server"} =
                 Secrets.resolve(secret_name(updated),
                   for: ConnectionSecrets.destination(updated)
                 )
      end
    end
  end

  describe "deleting a connection" do
    test "deletes its secret" do
      {:ok, conn} = Connections.create_connection(attrs())
      name = secret_name(conn)

      assert {:ok, _} = Connections.delete_connection(conn)
      assert Secrets.get(name) == nil
      assert {:error, :not_found} = Connections.get_by_name(conn.name)
    end
  end

  describe "no default, no fallback" do
    test "an unknown name is not found — never AlexClaw's own database" do
      assert {:error, :not_found} = Connections.get_by_name("alex_claw")
      assert {:error, :not_found} = Connections.get_by_name("default")
    end

    test "there is no connection until an admin defines one" do
      assert Connections.list_connections() == []
    end
  end
end
