defmodule AlexClawWeb.ConnCase do
  @moduledoc """
  Test case for controller tests that need a connection.
  Sets up Ecto sandbox and ETS tables.
  """
  use ExUnit.CaseTemplate

  alias AlexClaw.Auth.{Elevation, Sessions}
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import AlexClawWeb.ConnCase
      import AlexClaw.BypassHelper

      @endpoint AlexClawWeb.Endpoint
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(AlexClaw.Repo, shared: not tags[:async])

    # Drained first: a supervised audit task still holding the connection when
    # the owner is stopped fails whichever test runs next.
    on_exit(fn ->
      AlexClaw.TaskDrain.drain()
      Sandbox.stop_owner(pid)
    end)

    ensure_ets_table(:alexclaw_config)
    ensure_ets_table(:alexclaw_llm_usage)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Sign `conn` in as a live admin login, the way the login route does: the sid
  is opened in `AlexClaw.Auth.Sessions`, not merely written into the cookie.
  Pass a sid to control it, as tests of elevation do; a test that opens several
  pages with one sid signs in once.
  """
  def authenticate(conn, sid \\ Elevation.new_sid()) do
    unless Sessions.valid?(sid), do: :ok = Sessions.open(sid)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:elevation_sid, sid)
    |> Plug.Conn.put_session(:live_socket_id, Sessions.socket_id(sid))
  end

  defp ensure_ets_table(name) do
    case :ets.info(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set])
      _ -> :ets.delete_all_objects(name)
    end
  end
end
