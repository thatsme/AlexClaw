# Tests tagged :external reach real third-party endpoints (DuckDuckGo and the
# like). They are excluded by default so the suite is deterministic and offline;
# run them with `mix test --include external`.
ExUnit.configure(exclude: [:external])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, :manual)

Mox.defmock(AlexClaw.LLM.Mock, for: AlexClaw.LLM.Behaviour)
