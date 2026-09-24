defmodule AlexClaw.AsyncStreamTimeoutTest do
  @moduledoc """
  Every `async_stream` in lib/ says what happens when a task runs out of time
  (reports/SKILL_ERROR_SWALLOWING.md §1.4; 0.3.51).

  `Task.async_stream/3` with a `:timeout` and no `on_timeout: :kill_task`
  EXITS THE CALLER when one element is slow — the skill's own `_ -> []`
  clause is never reached. `web_search_fetch` and `web_search` fetched pages
  this way: one slow page took the whole step down.

  So every call to `Task.async_stream` or `Task.Supervisor.async_stream(_nolink)`
  in lib/ passes `on_timeout: :kill_task`, and the caller then handles
  `{:exit, :timeout}` like any other failed element.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  @stream_functions [:async_stream, :async_stream_nolink]

  defp calls_in(path) do
    {_ast, found} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {{:., meta, [{:__aliases__, _, mod}, fun]}, _, args} = node, acc
        when mod in [[:Task], [:Task, :Supervisor]] and fun in @stream_functions ->
          {node, [{path, meta[:line], args} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp options({_path, _line, args}) do
    args |> List.last() |> then(&if(Keyword.keyword?(&1), do: &1, else: []))
  end

  test "the scan finds the async_stream calls (no vacuous pass)" do
    calls = Enum.flat_map(Path.wildcard("lib/**/*.ex"), &calls_in/1)
    assert length(calls) >= 2, "found #{length(calls)} async_stream calls"
  end

  test "every async_stream kills a task that runs out of time instead of exiting the caller" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          call <- calls_in(path),
          options(call)[:on_timeout] != :kill_task,
          do: "#{elem(call, 0)}:#{elem(call, 1)}"

    assert offenders == [],
           "async_stream without on_timeout: :kill_task:\n  " <> Enum.join(offenders, "\n  ")
  end
end
