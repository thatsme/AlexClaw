defmodule AlexClaw.ConnectionsTargetTest do
  @moduledoc """
  A connection never points at AlexClaw itself or at its own services
  (reports/SQLREAD_ATTACKER_REVIEW.md L7): not its own database, not
  OpenBao, not the web automator — which would let a connection read
  AlexClaw's data, or make the connection page a scanner of its internal
  networks.

  Refused, at save and again before every connect (a name can resolve
  elsewhere later): loopback, "this network", link-local, and every address
  in AlexClaw's own networks (`:connection_internal_networks`; in the test
  stack, the network OpenBao is on). A customer's server on a private
  network of its own is a normal target.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Connections
  alias AlexClaw.Connections.{Connection, Pools}
  alias Ecto.Adapters.SQL.Sandbox

  defp attrs(host) do
    repo = Application.fetch_env!(:alex_claw, AlexClaw.Repo)

    %{
      name: "target_#{System.unique_integer([:positive])}",
      host: host,
      port: repo[:port] || 5432,
      database: repo[:database],
      username: repo[:username],
      tls_mode: "disable",
      password: repo[:password]
    }
  end

  defp host_errors(changeset),
    do: Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)[:host]

  for host <- ["localhost", "127.0.0.1", "127.8.9.10", "::1", "0.0.0.0", "169.254.169.254"] do
    test "#{host} is refused at save" do
      assert {:error, changeset} = Connections.create_connection(attrs(unquote(host)))
      assert Enum.join(host_errors(changeset)) =~ "AlexClaw's own"
    end
  end

  for host <- ["openbao-test", "10.213.64.2"] do
    test "#{host}, in AlexClaw's own networks, is refused at save" do
      assert {:error, changeset} = Connections.create_connection(attrs(unquote(host)))
      assert Enum.join(host_errors(changeset)) =~ "AlexClaw's own"
    end
  end

  test "a customer's server on a network of its own is accepted" do
    host = Application.fetch_env!(:alex_claw, AlexClaw.Repo)[:hostname]
    assert {:ok, %Connection{}} = Connections.create_connection(attrs(host))
  end

  test "a connection whose host became internal outside the save is never connected" do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    on_exit(fn -> Pools.stop_all() end)

    host = Application.fetch_env!(:alex_claw, AlexClaw.Repo)[:hostname]
    {:ok, conn} = Connections.create_connection(attrs(host))

    {1, _} =
      Connection
      |> where(id: ^conn.id)
      |> Repo.update_all(set: [host: "127.0.0.1"])

    :ok = Pools.sync(conn.name)
    Process.sleep(500)

    assert %{state: :down, reason: reason} = Pools.status(conn.name)
    assert reason =~ "AlexClaw's own"
  end
end
