ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, :manual)

Mox.defmock(AlexClaw.LLM.Mock, for: AlexClaw.LLM.Behaviour)
