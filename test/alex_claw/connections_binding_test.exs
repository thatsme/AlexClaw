defmodule AlexClaw.ConnectionsBindingTest do
  @moduledoc """
  A connection's password is bound to the server it was entered for — host,
  port, database, user and TLS mode — not only to the connection's name
  (reports/SQLREAD_ATTACKER_REVIEW.md H1). Whatever changes the row's server
  — a save, a restore, a write that bypasses both — the password no longer
  resolves for it until it is entered again.

  The rotation notice for a connection's password is sent once the save has
  committed: a pool still holding the old server never hears of the new
  password while the change can still be undone.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.Elevation
  alias AlexClaw.{Config, Connections, ControlPlane, SandboxCleanup, Secrets}
  alias AlexClaw.Connections.{Connection, ConnectionSecrets, Pools}
  alias AlexClaw.ControlPlane.Context

  @password "b1nding-Password-1"

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "bound_#{System.unique_integer([:positive])}",
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

  defp secret_name(%Connection{credentials: %{"password" => %{"secret" => name}}}), do: name

  # The row changed underneath the save path, as a restore or a direct write would.
  defp moved(conn, field, value) do
    {1, _} =
      Connection
      |> where(id: ^conn.id)
      |> Repo.update_all(set: [{field, value}])

    Repo.get!(Connection, conn.id)
  end

  describe "the binding names the server" do
    test "it is the connection's name and a fingerprint of its server, never the host in clear" do
      {:ok, conn} = Connections.create_connection(attrs())
      %Secrets.Secret{binding: [binding]} = Secrets.get(secret_name(conn))

      assert binding == ConnectionSecrets.destination(conn)
      assert binding =~ ~r/\Aconnection:#{conn.name}\.[0-9a-f]{32}\z/
      refute binding =~ "erp-db.example.com"
    end

    test "the same server gives the same binding; the host's case does not matter" do
      {:ok, conn} = Connections.create_connection(attrs())

      assert ConnectionSecrets.destination(conn) ==
               ConnectionSecrets.destination(%{conn | host: "ERP-DB.example.COM"})
    end

    for {field, value} <- [
          host: "attacker.example.net",
          port: 6543,
          database: "other",
          username: "someone_else",
          tls_mode: "disable"
        ] do
      test "a row whose #{field} changed outside the save no longer resolves the password" do
        {:ok, conn} = Connections.create_connection(attrs())
        assert {:ok, @password} = ConnectionSecrets.resolve(conn)

        moved = moved(conn, unquote(field), unquote(value))
        assert {:error, :not_bound} = ConnectionSecrets.resolve(moved)
      end
    end

    test "a password entered for a new server does not resolve for the old one" do
      {:ok, conn} = Connections.create_connection(attrs())

      {:ok, updated} =
        Connections.update_connection(conn, %{
          host: "new-db.example.com",
          password: "n3w-Server-pw"
        })

      assert {:ok, "n3w-Server-pw"} = ConnectionSecrets.resolve(updated)

      assert {:error, :not_bound} =
               Secrets.resolve(secret_name(updated), for: ConnectionSecrets.destination(conn))
    end
  end

  describe "the rotation notice" do
    setup do
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, Secrets.topic())
      :ok
    end

    test "inside an outer transaction it is held until that transaction has committed" do
      {:ok, conn} = Connections.create_connection(attrs())
      name = secret_name(conn)
      flush_notices()

      result =
        Repo.transaction(fn ->
          {:ok, _} =
            Connections.update_connection(conn, %{
              host: "new-db.example.com",
              password: "n3w-pw-123"
            })

          refute_received {:secret_rotated, ^name}, "the notice came before the commit"
        end)

      refute_received {:secret_rotated, ^name}
      Secrets.notify_after(result)
      assert_received {:secret_rotated, ^name}
    end

    test "is dropped when the outer transaction is undone" do
      {:ok, conn} = Connections.create_connection(attrs())
      name = secret_name(conn)
      flush_notices()

      result =
        Repo.transaction(fn ->
          {:ok, _} =
            Connections.update_connection(conn, %{
              host: "new-db.example.com",
              password: "n3w-pw-123"
            })

          Repo.rollback(:undone)
        end)

      assert {:error, :undone} = Secrets.notify_after(result)
      refute_received {:secret_rotated, ^name}
    end

    test "a save through the control plane notifies once it has committed" do
      {:ok, conn} = Connections.create_connection(attrs())
      name = secret_name(conn)
      flush_notices()

      sid = Elevation.new_sid()
      on_exit(fn -> SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
      on_exit(fn -> Pools.stop_all() end)
      Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
      {:ok, _} = Elevation.grant(sid)

      params = %{
        connection: conn,
        attrs: %{host: "new-db.example.com", password: "n3w-pw-456"},
        detail: "connection saved: #{conn.name}"
      }

      assert {:ok, _} = ControlPlane.perform(:save_connection, params, Context.admin_ui(sid))
      assert_received {:secret_rotated, ^name}
    end

    test "a save outside any transaction notifies at once" do
      {:ok, conn} = Connections.create_connection(attrs())
      name = secret_name(conn)
      flush_notices()

      {:ok, _} = Connections.update_connection(conn, %{password: "r0tated-pw-1"})
      assert_received {:secret_rotated, ^name}
    end
  end

  defp flush_notices do
    receive do
      {:secret_rotated, _} -> flush_notices()
    after
      0 -> :ok
    end
  end
end
