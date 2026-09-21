defmodule AlexClawWeb.AdminLive.ElevationInvariantTest do
  @moduledoc """
  Every control-plane write reachable from an admin page passes through a gate.

  The enforcement tests check the events that exist today. This one checks the
  events that will exist tomorrow: it reads the LiveViews' own source, follows
  each `handle_event` clause through the functions it calls, and fails when a
  clause can reach a write without reaching a gate.

  Following the calls matters — a handler that delegates its body to a private
  function is the normal shape here, and a check that only looked inside the
  clause itself would pass a page that had quietly stopped gating anything.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  @pages ~w(config policies llm resources cluster database workflows scheduler)

  # Writing a record, or starting work that writes one. Named by the module and
  # function as they appear in the source, because `run/1` on its own says
  # nothing: Executor.run starts a workflow, Restore.run replaces the database.
  @writes [
    {:Config, :set},
    {:Config, :delete},
    {:Repo, :insert},
    {:Repo, :insert!},
    {:Repo, :update},
    {:Repo, :update!},
    {:Repo, :delete},
    {:Repo, :delete!},
    {:Repo, :delete_all},
    {:Workflows, :create_workflow},
    {:Workflows, :update_workflow},
    {:Workflows, :delete_workflow},
    {:Workflows, :duplicate_workflow},
    {:Workflows, :import_workflow},
    {:Workflows, :create_step},
    {:Workflows, :update_step},
    {:Workflows, :delete_step},
    {:Workflows, :reorder_steps},
    {:Workflows, :assign_resource},
    {:Workflows, :unassign_resource},
    {:LLM, :create_provider},
    {:LLM, :update_provider},
    {:LLM, :delete_provider},
    {:Resources, :create_resource},
    {:Resources, :update_resource},
    {:Resources, :delete_resource},
    {:Cluster, :create_node},
    {:Cluster, :update_node},
    {:Cluster, :delete_node},
    {:AuditLog, :prune},
    {:Executor, :run},
    {:Restore, :run}
  ]

  # The ways a write is allowed to be reached. Elevation.gate is the
  # fifteen-minute window; Gate.request and ActionCode.request are a challenge
  # for this action alone, sent to a gateway and offered on the page;
  # Launch.start is the workflow's own requires_2fa rule, which decides between
  # them.
  @gates [
    {:Elevation, :gate},
    {:Elevation, :gated},
    {:Gate, :request},
    {:Launch, :start},
    {:ActionCode, :request}
  ]

  # An event that writes without a gate, deliberately. Empty, and each entry
  # would have to say why — "operational" is not a reason, it is a category.
  @allowed %{}

  defp source(page) do
    File.read!("lib/alex_claw_web/live/admin_live/#{page}.ex")
  end

  # name => {local calls, qualified calls}, for every function in the module.
  #
  # Clauses are merged rather than replaced. Keeping only the last clause would
  # lose exactly the interesting ones: `challenge(true, ...)` raises the
  # challenge, `challenge(false, ...)` is the bootstrap path, and a map keyed by
  # name alone would remember whichever came second.
  defp definitions(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, %{}, fn
        {marker, _meta, [head, body]} = node, acc when marker in [:def, :defp] ->
          {node, Map.update(acc, name_of(head), calls_in(body), &merge(&1, calls_in(body)))}

        node, acc ->
          {node, acc}
      end)

    defs
  end

  defp merge({local, qualified}, {more_local, more_qualified}) do
    {MapSet.union(local, more_local), MapSet.union(qualified, more_qualified)}
  end

  defp name_of({:when, _meta, [head | _guards]}), do: name_of(head)
  defp name_of({name, _meta, _args}) when is_atom(name), do: name
  defp name_of(other), do: other

  defp calls_in(body) do
    {_ast, calls} =
      Macro.prewalk(body, {MapSet.new(), MapSet.new()}, fn
        {{:., _, [{:__aliases__, _, mods}, fun]}, _meta, _args} = node, {local, qualified} ->
          {node, {local, MapSet.put(qualified, {List.last(mods), fun})}}

        {name, _meta, args} = node, {local, qualified} when is_atom(name) and is_list(args) ->
          {node, {MapSet.put(local, name), qualified}}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # Every qualified call reachable from a starting point, following local calls
  # through the module. Cycles terminate because `seen` only ever grows.
  defp reachable(defs, local, qualified, seen) do
    local
    |> Enum.reduce({qualified, seen}, fn name, {acc, visited} ->
      walk(defs, name, acc, visited)
    end)
    |> elem(0)
  end

  defp walk(defs, name, acc, seen), do: step(MapSet.member?(seen, name), defs, name, acc, seen)

  defp step(true, _defs, _name, acc, seen), do: {acc, seen}

  defp step(false, defs, name, acc, seen) do
    descend(defs[name], defs, acc, MapSet.put(seen, name))
  end

  defp descend(nil, _defs, acc, seen), do: {acc, seen}

  defp descend({local, qualified}, defs, acc, seen) do
    Enum.reduce(local, {MapSet.union(acc, qualified), seen}, fn name, {inner, visited} ->
      walk(defs, name, inner, visited)
    end)
  end

  # The handle_event clauses of a module, as {event name, reachable calls}.
  defp events(page) do
    ast = page |> source() |> Code.string_to_quoted!()
    defs = definitions(ast)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {marker, _meta, [head, body]} = node, acc when marker in [:def, :defp] ->
          {node, collect_event(name_of(head), head, body, defs, acc)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp collect_event(:handle_event, head, body, defs, acc) do
    case event_name(head) do
      nil -> acc
      name -> [{name, calls_from(body, defs)} | acc]
    end
  end

  defp collect_event(_name, _head, _body, _defs, acc), do: acc

  defp event_name({:when, _meta, [head | _guards]}), do: event_name(head)
  defp event_name({:handle_event, _meta, [name | _rest]}) when is_binary(name), do: name
  defp event_name(_head), do: nil

  defp calls_from(body, defs) do
    {local, qualified} = calls_in(body)
    reachable(defs, local, qualified, MapSet.new())
  end

  defp writes(calls), do: Enum.filter(@writes, &MapSet.member?(calls, &1))
  defp gates(calls), do: Enum.filter(@gates, &MapSet.member?(calls, &1))

  test "every write reachable from an admin event is reachable only through a gate" do
    ungated =
      for page <- @pages,
          {event, calls} <- events(page),
          found = writes(calls),
          found != [],
          gates(calls) == [],
          not Map.has_key?(@allowed, {page, event}),
          do: "#{page}.ex #{event} → #{inspect(found)}"

    assert ungated == [],
           """
           These admin events reach a write without passing through a gate:

             #{Enum.join(ungated, "\n  ")}

           Wrap the write in AlexClawWeb.Live.Elevation.gate/3, challenge it per
           action with Auth.Gate.request/2, or — if it genuinely needs neither —
           add it to @allowed in this file with the reason why.
           """
  end

  test "the pages this invariant covers still gate something" do
    # A page that stopped gating anything would pass the test above by having
    # nothing left to find, which is the failure mode this catches.
    gating = for page <- @pages, {_event, calls} <- events(page), gates(calls) != [], do: page

    for page <- @pages -- ["scheduler"] do
      assert page in gating, "#{page}.ex no longer gates any event"
    end
  end

  test "every allow-listed event still exists and still writes" do
    for {{page, event}, reason} <- @allowed do
      calls = events(page) |> Enum.find_value(fn {name, c} -> name == event && c end)

      assert calls, "#{page}.ex has no event #{event} — the allow-list entry is stale"

      assert writes(calls) != [],
             "#{page}.ex #{event} no longer writes; drop the allow-list entry (#{reason})"
    end
  end
end
