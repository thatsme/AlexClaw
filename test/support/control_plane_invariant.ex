defmodule AlexClaw.ControlPlaneInvariant do
  @moduledoc """
  Reads a LiveView's source and finds every control-plane write it can make
  outside `gated/3`.

  A write is allowed in exactly one place: inside the change handed to
  `AlexClaw.ControlPlane` — the `write:` of `Elevation.gated/3`, the write
  given to `ControlPlane.gated/4`, or the follow-up given to
  `ControlPlane.outcome/3` — and in private functions reached from there and
  from nowhere else. Everything else is outside the transaction: an event
  handler's own body, `after_commit:`, `ok:`, `error:`, or a helper that
  ungated code can also reach.

  Checking where a write sits, rather than whether a gate is reachable from
  the same event, is the stronger rule. An event that calls `gated/3` and also
  writes beside it would pass a reachability check; it does not pass this one.
  """

  # Writing a record, or starting work that writes one. Named by the module and
  # function as they appear in the source, because `run/1` on its own says
  # nothing: Executor.run starts a workflow, Restore.run replaces the database.
  @writes [
    {:Config, :set},
    {:Config, :delete},
    {:Config, :persist},
    {:Config, :remove},
    {:Repo, :insert},
    {:Repo, :insert!},
    {:Repo, :insert_all},
    {:Repo, :update},
    {:Repo, :update!},
    {:Repo, :update_all},
    {:Repo, :delete},
    {:Repo, :delete!},
    {:Repo, :delete_all},
    {:Workflows, :create_workflow},
    {:Workflows, :update_workflow},
    {:Workflows, :delete_workflow},
    {:Workflows, :duplicate_workflow},
    {:Workflows, :import_workflow},
    {:Workflows, :add_step},
    {:Workflows, :update_step},
    {:Workflows, :remove_step},
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
    {:Cluster, :refresh_statuses},
    {:AuditLog, :prune},
    {:Executor, :run},
    {:Restore, :run}
  ]

  @doc "The writes this invariant recognises."
  def writes, do: @writes

  @doc """
  `{function, [write]}` for every function in `source` that can make a write
  outside a gated change, directly or through a helper.
  """
  def violations(source) do
    defs = source |> Code.string_to_quoted!() |> definitions()
    gated_only = reachable(defs, :gated) -- reachable(defs, :ungated)

    for {name, %{ungated: {_local, qualified}}} <- defs,
        name not in gated_only,
        found = Enum.filter(@writes, &MapSet.member?(qualified, &1)),
        found != [],
        do: {name, found}
  end

  # Every function reachable from gated code, or from ungated code, following
  # local calls. Public functions are where ungated code starts: events,
  # callbacks, anything the module exposes.
  defp reachable(defs, kind) do
    roots =
      defs
      |> Enum.flat_map(fn {name, parts} -> roots(kind, name, parts) end)
      |> Enum.uniq()

    walk(defs, roots, MapSet.new(), kind) |> MapSet.to_list()
  end

  defp roots(:gated, _name, %{gated: {local, _}}), do: MapSet.to_list(local)
  defp roots(:ungated, name, %{public?: true}), do: [name]
  defp roots(:ungated, _name, _parts), do: []

  defp walk(_defs, [], seen, _kind), do: seen

  defp walk(defs, [name | rest], seen, kind) do
    walk_one(MapSet.member?(seen, name), defs, name, rest, seen, kind)
  end

  defp walk_one(true, defs, _name, rest, seen, kind), do: walk(defs, rest, seen, kind)

  # A function reached from gated code is gated in its entirety; one reached
  # from ungated code passes on only its ungated calls.
  defp walk_one(false, defs, name, rest, seen, kind) do
    next = defs |> Map.get(name, %{}) |> next_calls(kind)
    walk(defs, next ++ rest, MapSet.put(seen, name), kind)
  end

  defp next_calls(%{ungated: {local, _}, gated: {glocal, _}}, :gated),
    do: MapSet.to_list(MapSet.union(local, glocal))

  defp next_calls(%{ungated: {local, _}}, :ungated), do: MapSet.to_list(local)
  defp next_calls(_parts, _kind), do: []

  # name => %{public?, ungated: {local, qualified}, gated: {local, qualified}}
  # Clauses of one function are merged: every clause is part of it.
  defp definitions(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, %{}, fn
        {marker, _meta, [head, body]} = node, acc when marker in [:def, :defp] ->
          parts = %{
            public?: marker == :def,
            ungated: calls(body, :ungated),
            gated: calls(body, :gated)
          }

          {node, Map.update(acc, name_of(head), parts, &merge(&1, parts))}

        node, acc ->
          {node, acc}
      end)

    defs
  end

  defp merge(a, b) do
    %{
      public?: a.public? or b.public?,
      ungated: union(a.ungated, b.ungated),
      gated: union(a.gated, b.gated)
    }
  end

  defp union({l1, q1}, {l2, q2}), do: {MapSet.union(l1, l2), MapSet.union(q1, q2)}

  defp name_of({:when, _meta, [head | _guards]}), do: name_of(head)
  defp name_of({name, _meta, _args}) when is_atom(name), do: name
  defp name_of(other), do: other

  # The calls in `body` that sit outside every gated change (:ungated), or
  # inside one (:gated).
  defp calls(body, kind) do
    body
    |> split()
    |> Map.fetch!(kind)
    |> Enum.reduce({MapSet.new(), MapSet.new()}, fn tree, acc -> union(acc, calls_in(tree)) end)
  end

  # Separate the gated changes out of a body: %{gated: [tree], ungated: [tree]}.
  defp split(body) do
    {ungated, gated} =
      Macro.prewalk(body, [], fn node, acc ->
        case gated_parts(node) do
          [] -> {node, acc}
          parts -> {strip(node, parts), parts ++ acc}
        end
      end)

    %{ungated: [ungated], gated: gated}
  end

  # Elevation.gated(socket, detail, write: fun, ...)
  defp gated_parts({{:., _, [{:__aliases__, _, aliases}, :gated]}, _, [_socket, _detail, opts]})
       when is_list(opts) do
    if List.last(aliases) == :Elevation,
      do: Keyword.take(opts, [:write]) |> Keyword.values(),
      else: []
  end

  # ControlPlane.gated(sid, detail, write) and ControlPlane.gated(sid, detail, write, after)
  defp gated_parts({{:., _, [{:__aliases__, _, aliases}, :gated]}, _, [_sid, _detail, write | _]}) do
    if List.last(aliases) == :ControlPlane, do: [write], else: []
  end

  # ControlPlane.outcome(sid, detail, write)
  defp gated_parts({{:., _, [{:__aliases__, _, aliases}, :outcome]}, _, [_sid, _detail, write]}) do
    if List.last(aliases) == :ControlPlane, do: [write], else: []
  end

  defp gated_parts(_node), do: []

  # Replace the gated parts of a call with a placeholder, so the ungated walk
  # does not descend into them.
  defp strip(node, parts) do
    Macro.prewalk(node, fn sub -> if sub in parts, do: :gated_change, else: sub end)
  end

  defp calls_in(tree) do
    {_ast, found} = Macro.prewalk(tree, {MapSet.new(), MapSet.new()}, &collect/2)
    found
  end

  defp collect(
         {{:., _, [{:__aliases__, _, mods}, fun]}, _meta, _args} = node,
         {local, qualified}
       ),
       do: {node, {local, MapSet.put(qualified, {List.last(mods), fun})}}

  defp collect({:&, _, [{:/, _, [{name, _, _}, _arity]}]} = node, {local, qualified})
       when is_atom(name),
       do: {node, {MapSet.put(local, name), qualified}}

  defp collect({name, _meta, args} = node, {local, qualified})
       when is_atom(name) and is_list(args),
       do: {node, {MapSet.put(local, name), qualified}}

  defp collect(node, acc), do: {node, acc}
end
