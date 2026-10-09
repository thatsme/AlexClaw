defmodule AlexClaw.Connections.QueryNarrowRowsTest do
  @moduledoc """
  The query process's memory bound is sized against the 5 MB cap with each
  row's overhead counted (reports/SQLREAD_FIX_REVIEW.md F3): a result just
  under the cap is never refused as too large, whatever the shape of its
  rows. Narrow rows are the worst case — a few bytes of JSON each, but a
  map, a list cell and the driver's row in memory.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Connections
  alias AlexClaw.Connections.{Pools, Query}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    on_exit(fn -> Pools.stop_all() end)

    repo = Application.fetch_env!(:alex_claw, AlexClaw.Repo)

    {:ok, conn} =
      Connections.create_connection(%{
        name: "narrow",
        host: repo[:hostname],
        port: repo[:port] || 5432,
        database: repo[:database],
        username: repo[:username],
        tls_mode: "disable",
        password: repo[:password]
      })

    :ok = Pools.sync(conn.name)
    up(conn.name, 50)
    %{name: conn.name}
  end

  defp up(name, 0), do: flunk("#{name} never came up: #{inspect(Pools.status(name))}")

  defp up(name, tries) do
    case Pools.status(name) do
      %{state: :up} ->
        :ok

      _other ->
        Process.sleep(100)
        up(name, tries - 1)
    end
  end

  defp json_size(%{"rows" => rows}), do: rows |> Jason.encode!() |> byte_size()

  # Each query's rows encode to between 4.5 and 5 MB of JSON.
  @shapes [
    {"one one-digit integer column", "SELECT (g % 10) AS n FROM generate_series(1, 600000) g",
     600_000},
    {"one NULL column", "SELECT NULL::int AS x FROM generate_series(1, 440000) g", 440_000},
    {"twenty boolean columns",
     "SELECT " <>
       Enum.map_join(1..20, ", ", &"true AS b#{&1}") <>
       " FROM generate_series(1, 23000) g", 23_000}
  ]

  # Rows of no columns cost the most per byte of JSON ("{}"), and a statement
  # without columns reads nothing a step can use; SELECT … INTO is one.
  for sql <- ["SELECT FROM generate_series(1, 10) g", "SELECT 1 AS a INTO zz_never_created"] do
    test "#{sql} is refused: it returns no columns", %{name: name} do
      assert {:error, {:not_read_only, why}} =
               Query.run(name, unquote(sql), [], deadline_ms: 5_000)

      assert why =~ "no columns"
      assert {:error, {:not_read_only, _}} = Query.dry_run(name, unquote(sql), [])
    end
  end

  for {label, sql, count} <- @shapes do
    test "#{label}, just under the cap, is read whole", %{name: name} do
      assert {:ok, %{"row_count" => unquote(count)} = result} =
               Query.run(name, unquote(sql), [], deadline_ms: 60_000)

      size = json_size(result)
      assert size > 4_500_000 and size < 5_000_000, "the shape is #{size} bytes of JSON"
    end
  end
end
