defmodule AlexClaw.Gateway.SupervisionIsolationTest do
  @moduledoc """
  A gateway that keeps crashing must not stop the application
  (reports/GATEWAY_CRASH_2026-09-23.md §6).

  The Telegram gateway was a direct child of the root supervisor, whose
  restart intensity is the default 3 in 5 s. Four gateway crashes in 3.2 s
  exceeded it: the root terminated every child, the node stopped, and Docker
  restarted the container. Any child crashing four times in five seconds
  would have done the same.

  Now the gateways live under their own supervisor, a child of the root. A
  crash storm there can use up that supervisor's intensity, and the root
  restarts it once — the rest of the application never notices. After the
  storm the gateway is running again.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  @root AlexClaw.Supervisor
  @gateway AlexClaw.Gateway.Telegram

  defp eventually(check, attempts \\ 100) do
    Enum.any?(1..attempts, fn _ -> check.() or (Process.sleep(50) && false) end)
  end

  defp gateway_pid do
    case Process.whereis(@gateway) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      _ -> nil
    end
  end

  test "the gateway is not a direct child of the root supervisor" do
    direct = for {id, _pid, _type, _mods} <- Supervisor.which_children(@root), do: id
    refute @gateway in direct, "#{inspect(@gateway)} is still a direct child of #{inspect(@root)}"
  end

  test "a crash storm in the gateway leaves the root supervisor and its other children in place" do
    assert gateway_pid(), "premise: the Telegram gateway runs in the test environment"

    # With the gateway still a direct child, this storm would stop the test
    # node itself (that is the bug). Refuse to run it until isolation exists,
    # so the red run fails here instead of taking the whole suite down.
    direct = for {id, _pid, _type, _mods} <- Supervisor.which_children(@root), do: id

    if @gateway in direct,
      do: flunk("not isolated yet: a storm would stop the application under test")

    root = Process.whereis(@root)

    others =
      for {id, pid, _type, _mods} <- Supervisor.which_children(@root), is_pid(pid), do: {id, pid}

    # Six kills in quick succession: more than any default intensity allows.
    for _ <- 1..6 do
      assert eventually(fn -> gateway_pid() != nil end), "the gateway did not come back"
      Process.exit(gateway_pid(), :kill)
      Process.sleep(20)
    end

    assert Process.whereis(@root) == root, "the root supervisor was restarted"
    assert Process.alive?(root)

    # Every other child of the root is the same process as before the storm,
    # except the gateways' own supervisor, which may have been restarted once.
    survivors = Map.new(Supervisor.which_children(@root), fn {id, pid, _, _} -> {id, pid} end)

    restarted =
      for {id, pid} <- others, survivors[id] != pid, do: id

    assert length(restarted) <= 1,
           "children of the root restarted by a gateway storm: #{inspect(restarted)}"

    assert eventually(fn -> gateway_pid() != nil end),
           "the gateway is not running after the storm"
  end
end
