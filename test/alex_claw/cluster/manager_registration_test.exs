defmodule AlexClaw.Cluster.ManagerRegistrationTest do
  @moduledoc """
  Registering a node when the database is not there.

  The manager writes a row saying "this node is up". That is worth retrying and
  not worth blocking for: unlike the configuration, a node can run for a moment
  without its row, and the row says the same thing a second later. So the write
  left `init/1` for `handle_continue/2`, and a failure schedules another go
  instead of killing the process.

  The unreachable database is a non-shared sandbox — a process with no checkout
  cannot query — and `Sandbox.allow/3` is the database arriving.

  A named node is used rather than this one: `node()` is `:nonode@nohost` under
  `mix test`, and a VM with no name has nothing to register, so self-registration
  is a no-op here. The path is the same either way — both go through
  `register/2`.
  """
  use AlexClaw.DataCase, async: true
  @moduletag :integration

  alias AlexClaw.Cluster
  alias AlexClaw.Cluster.Manager
  alias Ecto.Adapters.SQL.Sandbox

  @probe "probe@registration-test.invalid"

  setup do
    %{manager: Process.whereis(Manager)}
  end

  test "an unreachable database does not take the manager down", %{manager: manager} do
    ref = Process.monitor(manager)

    send(manager, {:register, @probe, 0})

    refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 300
    assert Process.alive?(manager)
    assert Process.whereis(Manager) == manager, "the manager was restarted"
    assert Cluster.get_by_name(@probe) == nil, "the row was written without a database"
  end

  # The point of the retry: the row is owed, not abandoned.
  test "the node is registered on the retry once the database answers", ctx do
    owner = self()

    send(ctx.manager, {:register, @probe, 0})

    # The first attempt has to have failed before the database arrives, or the
    # retry is never what writes the row and this passes without one.
    Process.sleep(200)
    assert Cluster.get_by_name(@probe) == nil, "the first attempt did not fail"

    Sandbox.allow(Repo, owner, ctx.manager)

    assert eventually(fn -> Cluster.get_by_name(@probe) != nil end),
           "the retry never registered the node after the database came back"
  end

  # Long enough for the whole ladder, not just its first rung. The count rides
  # on the message, so a retry asked for here starts at 1s — but on a loaded
  # machine that first retry can itself land before Sandbox.allow/3 has taken
  # effect, and then the next is 2s, then 5s. A 4s window passed on a quiet
  # laptop and failed in CI. A run that never retries still fails, just slowly,
  # which is the right way round.
  defp eventually(check, remaining_ms \\ 20_000)
  defp eventually(_check, remaining_ms) when remaining_ms <= 0, do: false

  defp eventually(check, remaining_ms) do
    case check.() do
      true ->
        true

      false ->
        Process.sleep(100)
        eventually(check, remaining_ms - 100)
    end
  end
end
