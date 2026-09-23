defmodule AlexClaw.ApiMapTest do
  @moduledoc """
  `mix alex_claw.api_map` renders every kind of entry it promises. A map that
  rendered nothing would still be written without complaint; this checks one
  entry of each kind, from modules that exist for other reasons.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Mix.Tasks.AlexClaw.ApiMap

  test "the map holds each kind of entry, and only modules from lib/" do
    map = ApiMap.render()

    assert map =~ "## AlexClaw.LLM\n"
    assert map =~ "`@spec complete_fitted("
    assert map =~ "- `AlexClaw.Skill`: "
    assert map =~ "**Schema (llm_providers)**"
    assert map =~ "- `tier`: `:string`"
    assert map =~ "**handle_event**"
    refute map =~ "test/support"
  end
end
