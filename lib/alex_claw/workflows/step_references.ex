defmodule AlexClaw.Workflows.StepReferences do
  @moduledoc """
  How a step's references follow a renumbering. A route's `goto` and a step's
  `input_from` name a position; given `moved` (old position => new position),
  each points where its step went. `"end"`, a position not in `moved`, and
  anything that is not a position are left as they are.

  The one rule shared by reordering and removing steps (`AlexClaw.Workflows`)
  and by the upgrade repair of duplicate positions
  (`AlexClaw.Workflows.PositionRepair`).
  """

  @doc "The route with its `goto` moved, when that is a position."
  @spec moved_route(map(), %{integer() => integer()}) :: map()
  def moved_route(%{"goto" => goto} = route, moved) when is_integer(goto),
    do: %{route | "goto" => moved_position(goto, moved)}

  def moved_route(route, _moved), do: route

  @doc "The position `position` moved to, or `position` itself when it did not move."
  @spec moved_position(term(), %{integer() => integer()}) :: term()
  def moved_position(position, moved) when is_integer(position),
    do: Map.get(moved, position, position)

  def moved_position(other, _moved), do: other
end
