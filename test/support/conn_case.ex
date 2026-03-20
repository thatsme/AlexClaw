defmodule AlexClawWeb.ConnCase do
  @moduledoc """
  Test case for controller tests that need a connection.
  Sets up Ecto sandbox and ETS tables.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import AlexClawWeb.ConnCase

      @endpoint AlexClawWeb.Endpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AlexClaw.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    ensure_ets_table(:alexclaw_config)
    ensure_ets_table(:alexclaw_llm_usage)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Set session to authenticated for the given conn."
  def authenticate(conn) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:authenticated, true)
  end

  defp ensure_ets_table(name) do
    case :ets.info(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set])
      _ -> :ets.delete_all_objects(name)
    end
  end
end
