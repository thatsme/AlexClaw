defmodule AlexClawWeb.AdminLive.ElevationInvariantTest do
  @moduledoc """
  No LiveView makes a control-plane write outside the one door.

  The enforcement tests check the events that exist today. This one checks the
  events that will exist tomorrow: it reads every LiveView's source and fails
  when a write sits anywhere but inside a gated change — see
  `AlexClaw.ControlPlaneInvariant` for exactly where that is. Since 0.4.0 (S5a)
  the pages hand their changes to `ControlPlane.perform/3` through
  `Elevation.perform/4`, so a page normally makes no write at all;
  gate_boundary_test.exs pins the same rule from the other side.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  alias AlexClaw.ControlPlaneInvariant, as: Invariant

  @live_views Path.wildcard("lib/alex_claw_web/live/**/*.ex")

  # The pages whose changes are control-plane changes, each of which must still
  # make them through the one door (Elevation.perform/4, or the older
  # Elevation.gated for what S5 has not moved yet).
  @control_plane ~w(config policies llm resources cluster workflows memory)

  # A write outside the door, deliberately: {file, function, write} => why.
  # Each entry has to say why — "operational" is not a reason, it is a category.
  # (The 2FA-enrolment discard in services.ex left this list in S5a: it goes
  # through the door now, as set_up_second_factor.)
  @allowed %{
    {"cluster.ex", :handle_event, {:Cluster, :refresh_statuses}} =>
      "Records which nodes answered a ping. It observes the cluster; it changes " <>
        "nothing about which nodes belong to it or what they run.",
    {"cluster.ex", :handle_info, {:Cluster, :refresh_statuses}} =>
      "The same observation as the refresh button, on the page's thirty-second timer."
  }

  defp violations do
    for path <- @live_views,
        {function, writes} <- Invariant.violations(File.read!(path)),
        write <- writes,
        not Map.has_key?(@allowed, {Path.basename(path), function, write}),
        do: "#{Path.basename(path)} #{function} → #{inspect(write)}"
  end

  test "no LiveView makes a control-plane write outside gated/3" do
    assert violations() == [],
           """
           These LiveViews make a control-plane write outside gated/3:

             #{Enum.join(violations(), "\n  ")}

           Make the change through AlexClawWeb.Live.Elevation.gated/3, with the
           write in its write: function. after_commit: is outside the transaction
           and does not count. If the write genuinely is not a control-plane
           change, add it to @allowed in this file with the reason why.
           """
  end

  test "the control-plane pages still make their changes through the door" do
    # A page that stopped gating anything would pass the test above by having
    # nothing left to find, which is the failure mode this catches.
    for page <- @control_plane do
      source = File.read!("lib/alex_claw_web/live/admin_live/#{page}.ex")

      assert door_calls(source) > 0,
             "#{page}.ex no longer changes anything through the door"
    end
  end

  # Calls to Elevation.perform or Elevation.gated in the code itself: a
  # mention in a comment, a doc or a string does not count (S8: the check was
  # once a text match, which any of those satisfied).
  defp door_calls(source) do
    {_ast, count} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(0, fn
        {{:., _, [{:__aliases__, _, [:Elevation]}, fun]}, _, _} = node, n
        when fun in [:perform, :gated] ->
          {node, n + 1}

        node, n ->
          {node, n}
      end)

    count
  end

  test "a mention of the door in a comment or a string is not a call to it" do
    assert door_calls("""
           defmodule Probe do
             # Elevation.perform(socket, :x, %{}, [])
             @doc "Elevation.gated(socket, ...)"
             def f, do: "Elevation.perform("
           end
           """) == 0

    assert door_calls("defmodule P do\n def f(s), do: Elevation.perform(s, :x, %{}, [])\nend") ==
             1
  end

  test "every allow-listed write still exists" do
    for {{file, function, write}, reason} <- @allowed do
      [path] = Enum.filter(@live_views, &(Path.basename(&1) == file))
      found = Invariant.violations(File.read!(path))

      assert write in Keyword.get(found, function, []),
             "#{file} #{function} no longer makes #{inspect(write)}; drop the entry (#{reason})"
    end
  end

  describe "the invariant itself" do
    defp check(body) do
      Invariant.violations("""
      defmodule Probe do
        #{body}
      end
      """)
    end

    test "flags a write in an event handler" do
      assert [{:handle_event, [{:Repo, :insert}]}] =
               check("""
               def handle_event("x", _, s) do
                 Repo.insert(%Thing{})
                 s
               end
               """)
    end

    test "accepts a write inside gated/3's write:" do
      assert check("""
             def handle_event("x", _, s) do
               Elevation.gated(s, "d", write: fn -> Repo.insert(%Thing{}) end, ok: fn s, _ -> s end)
             end
             """) == []
    end

    test "flags a write in after_commit:, which is outside the transaction" do
      assert [{:handle_event, [{:Repo, :update}]}] =
               check("""
               def handle_event("x", _, s) do
                 Elevation.gated(s, "d",
                   write: fn -> {:ok, 1} end,
                   after_commit: fn _ -> Repo.update(%Thing{}) end,
                   ok: fn s, _ -> s end
                 )
               end
               """)
    end

    test "flags a write beside a gated change in the same event" do
      assert [{:handle_event, [{:Config, :set}]}] =
               check("""
               def handle_event("x", _, s) do
                 Config.set("k", "v")
                 Elevation.gated(s, "d", write: fn -> {:ok, 1} end, ok: fn s, _ -> s end)
               end
               """)
    end

    test "accepts a helper reached only from write:, and flags one also reached from outside" do
      assert check("""
             def handle_event("x", _, s), do: Elevation.gated(s, "d", write: &persist/0, ok: fn s, _ -> s end)
             defp persist, do: Repo.insert(%Thing{})
             """) == []

      assert [{:persist, [{:Repo, :insert}]}] =
               check("""
               def handle_event("x", _, s), do: Elevation.gated(s, "d", write: &persist/0, ok: fn s, _ -> s end)
               def handle_event("y", _, s), do: {persist(), s}
               defp persist, do: Repo.insert(%Thing{})
               """)
    end

    test "accepts a follow-up write inside ControlPlane.outcome/3" do
      assert check("""
             def handle_event("x", _, s) do
               Elevation.gated(s, "d",
                 write: fn -> {:ok, 1} end,
                 after_commit: fn _ -> ControlPlane.outcome(nil, "o", fn -> Cluster.update_node(1, %{}) end) end,
                 ok: fn s, _ -> s end
               )
             end
             """) == []
    end

    test "gated/3 on some other module is not a gate" do
      assert [{:handle_event, [{:Repo, :delete}]}] =
               check("""
               def handle_event("x", _, s), do: Other.gated(s, "d", write: fn -> Repo.delete(1) end)
               """)
    end
  end
end
