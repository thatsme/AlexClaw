# Tests tagged :external reach real third-party endpoints (DuckDuckGo and the
# like). They are excluded by default so the suite is deterministic and offline;
# run them with `mix test --include external`.
ExUnit.configure(exclude: [:external])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, :manual)

Mox.defmock(AlexClaw.LLM.Mock, for: AlexClaw.LLM.Behaviour)

# The Nostrum calls the Discord gateway makes, behind one behaviour so a test
# can make a send fail (reports/SECOND_ROUND_SEAMS.md §2; 0.3.53).
Mox.defmock(AlexClaw.Gateway.Discord.APIMock, for: AlexClaw.Gateway.Discord.API)
