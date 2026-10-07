defmodule AlexClaw.ConnectionsSecretPerBindingTest do
  @moduledoc """
  Each password a connection is given is a secret of its own
  (reports/SQLREAD_FIX_REVIEW.md F1, F5). OpenBao cannot undo a write, but
  a new secret can simply be forgotten:

  - a new password is written under a new secret, bound to the server it was
    entered for; the connection is committed pointing at it; the old secret
    is deleted only once that commit has happened;
  - a save undone after the new password was written leaves the connection
    on its old secret — old password, old binding — and removes the new
    secret from OpenBao (no orphan);
  - the same when the outermost transaction raises, and nothing held for it
    (a rotation notice, a deletion) is carried into a later, unrelated
    commit.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.{Connections, Secrets, Vault}
  alias AlexClaw.Connections.{Connection, ConnectionSecrets}

  @password "f1rst-Server-pw"

  defp attrs do
    %{
      name: "per_binding_#{System.unique_integer([:positive])}",
      host: "erp-a.example.com",
      port: 5432,
      database: "erp",
      username: "reader",
      tls_mode: "verify_full",
      password: @password
    }
  end

  defp secret_name(%Connection{credentials: %{"password" => %{"secret" => name}}}), do: name
  defp stored?(name), do: match?({:ok, _}, Vault.read("alexclaw/secrets/" <> name))

  defp flush_notices do
    receive do
      {:secret_rotated, _} -> flush_notices()
    after
      0 -> :ok
    end
  end

  test "a new password is a new secret; the old one is deleted once the save has committed" do
    {:ok, conn} = Connections.create_connection(attrs())
    old = secret_name(conn)

    {:ok, updated} =
      Connections.update_connection(conn, %{host: "erp-b.example.com", password: "s3cond-pw"})

    new = secret_name(updated)
    refute new == old
    assert {:ok, "s3cond-pw"} = ConnectionSecrets.resolve(updated)
    assert Secrets.get(old) == nil
    refute stored?(old)
  end

  test "a new password for the same server is a new secret too" do
    {:ok, conn} = Connections.create_connection(attrs())
    {:ok, updated} = Connections.update_connection(conn, %{password: "r0tated-pw"})

    refute secret_name(updated) == secret_name(conn)
    assert Secrets.get(secret_name(conn)) == nil
  end

  test "a save undone after the new password was written leaves the old secret, binding and password" do
    {:ok, conn} = Connections.create_connection(attrs())
    old = secret_name(conn)

    result =
      Secrets.transaction(fn ->
        {:ok, updated} =
          Connections.update_connection(conn, %{host: "erp-b.example.com", password: "s3cond-pw"})

        Repo.rollback({:undone, secret_name(updated)})
      end)

    assert {:error, {:undone, new}} = result
    reloaded = Repo.get!(Connection, conn.id)

    assert secret_name(reloaded) == old
    assert reloaded.host == "erp-a.example.com"
    assert {:ok, @password} = ConnectionSecrets.resolve(reloaded)
    assert Secrets.get(old).binding == [ConnectionSecrets.destination(reloaded)]

    assert Secrets.get(new) == nil
    refute stored?(new), "the new secret was left in OpenBao"
  end

  test "a raise in the outermost transaction undoes the same, and holds nothing for later" do
    Phoenix.PubSub.subscribe(AlexClaw.PubSub, Secrets.topic())
    {:ok, conn} = Connections.create_connection(attrs())
    old = secret_name(conn)
    flush_notices()
    test_pid = self()

    assert_raise RuntimeError, "boom", fn ->
      Secrets.transaction(fn ->
        {:ok, updated} =
          Connections.update_connection(conn, %{host: "erp-b.example.com", password: "s3cond-pw"})

        send(test_pid, {:new, secret_name(updated)})
        raise "boom"
      end)
    end

    assert_received {:new, new}
    refute stored?(new), "the new secret was left in OpenBao"
    assert {:ok, @password} = ConnectionSecrets.resolve(Repo.get!(Connection, conn.id))

    # A later, unrelated commit carries nothing the raise left behind.
    {:ok, _} = Secrets.transaction(fn -> :unrelated end)
    refute_received {:secret_rotated, ^new}
    refute_received {:secret_rotated, ^old}
    assert Secrets.get(old) != nil
  end
end
