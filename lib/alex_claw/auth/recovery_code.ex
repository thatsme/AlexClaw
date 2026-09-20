defmodule AlexClaw.Auth.RecoveryCode do
  @moduledoc "Ecto schema for one stored recovery code hash."
  use Ecto.Schema

  schema "auth_recovery_codes" do
    field(:hash, :string)
    field(:used_at, :utc_datetime)

    field(:inserted_at, :utc_datetime)
  end

  @type t :: %__MODULE__{}
end
