defmodule AlexClaw.Repo do
  @moduledoc "Ecto repository for AlexClaw's PostgreSQL database."

  use Ecto.Repo,
    otp_app: :alex_claw,
    adapter: Ecto.Adapters.Postgres
end
