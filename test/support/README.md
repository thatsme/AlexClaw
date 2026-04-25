# test/support

Test-only modules. Compiled in `:test` env via `elixirc_paths: ["lib", "test/support"]` in `mix.exs`.

## EchoSkill

`AlexClawTest.Skills.EchoSkill` — minimal `@behaviour AlexClaw.Skill` implementation used by `Reasoning.Loop` integration tests. Behavior driven by input string:

- `"fail"` substring → `{:error, :echo_failed}`
- `"raise"` substring → raises
- otherwise → `{:ok, "echoed: <input>"}`

Register in test setup via `AlexClawTest.ReasoningLoopHelper.register_echo_skill/0`. Unregister in `on_exit/1` to keep the global ETS table clean between tests.

## ReasoningLoopHelper

JSON fixture builders for each Loop phase (`plan_response`, `execution_response`, `evaluation_response`, `decision_response`) plus the EchoSkill registration helpers. Use these instead of hand-rolling JSON in tests so canned responses stay aligned with what `PromptParser` expects.

## BypassHelper

HTTP-level mocks for the LLM provider wire format. Used by `LLM.Client` integration tests where the wire shape matters. Higher-level tests should use the Mox mock (`AlexClaw.LLM.Mock`, defined in `test/test_helper.exs`) instead.
