defmodule AlexClaw.Config.LoaderBootTest do
  @moduledoc """
  What the configuration loader does when the database is not there yet.

  It is the one process that blocks. Skills and usage counts can be loaded
  later and the app is still itself without them; configuration cannot, because
  an agent running on defaults nobody chose is worse than one that does not
  run. So the loader waits, and when the wait runs out it stops the boot rather
  than continuing with an empty table.

  Two things shape how this is tested.

  `init/1` is called directly, not started as a process: the loader is a named
  singleton already running in this VM, and it is the callback's contract that
  matters. It is also not re-entrant — `QueryRewriter.init_cache/0` creates a
  named table and the second call raises — so a boot that gets past the wait
  cannot be followed to the end here. Getting past the wait is the observable,
  and that is what the last test asserts.

  The unreachable database is a non-shared sandbox: a process with no checkout
  cannot query, and `Sandbox.allow/3` is the database arriving. It has to be a
  bare `spawn` rather than a `Task`, because a task inherits `$callers` and the
  sandbox follows those straight back to this process's connection — which
  would make the database reachable after all, and the test pass for no reason.
  """
  use AlexClaw.DataCase, async: true
  @moduletag :integration

  alias AlexClaw.Config.Loader
  alias Ecto.Adapters.SQL.Sandbox

  test "stops the boot when the database never answers" do
    # A budget of zero makes the first failed probe the last one.
    assert isolated_init([database_wait_ms: 0], 5_000) ==
             {:returned, {:stop, :database_unavailable}}
  end

  # The bound is what separates a clear failure from a container that never
  # reports unhealthy and never restarts.
  test "the wait is bounded rather than indefinite" do
    started = System.monotonic_time(:millisecond)

    assert isolated_init([database_wait_ms: 1_000], 20_000) ==
             {:returned, {:stop, :database_unavailable}}

    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed >= 900,
           "returned after #{elapsed}ms against a 1s budget — it did not wait at all"

    assert elapsed < 10_000, "waited #{elapsed}ms against a 1s budget"
  end

  test "gets past the wait when the database answers inside the budget" do
    owner = self()
    {pid, ref} = spawn_init([])

    # Long enough that the first probe has failed and the loader is sleeping.
    # The database then arrives, and the retry finds it.
    Process.sleep(1_200)
    Sandbox.allow(Repo, owner, pid)

    result = await_init(pid, ref, 30_000)

    refute result == {:returned, {:stop, :database_unavailable}},
           "the loader gave up although the database answered inside the budget"
  end

  # A bare spawn: no $callers, so the sandbox has nothing to follow and the
  # database really is unreachable from in there.
  defp spawn_init(opts) do
    owner = self()

    spawn_monitor(fn ->
      send(owner, {:init_returned, self(), Loader.init(opts)})
    end)
  end

  defp await_init(pid, ref, timeout) do
    receive do
      {:init_returned, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        {:returned, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:raised, reason}
    after
      timeout -> flunk("Loader.init/1 neither returned nor failed within #{timeout}ms")
    end
  end

  defp isolated_init(opts, timeout) do
    {pid, ref} = spawn_init(opts)
    await_init(pid, ref, timeout)
  end
end
