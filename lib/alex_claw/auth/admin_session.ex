defmodule AlexClaw.Auth.AdminSession do
  @moduledoc "Ecto schema for a live admin login. Written only by `AlexClaw.Auth.Sessions`."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "admin_sessions" do
    field(:token_hash, :binary)
    field(:password_fingerprint, :binary)
    field(:inserted_at, :utc_datetime)
  end

  @doc "Changeset for a new login row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> Ecto.Changeset.cast(attrs, [:token_hash, :password_fingerprint, :inserted_at])
    |> Ecto.Changeset.validate_required([:token_hash, :password_fingerprint, :inserted_at])
    |> Ecto.Changeset.unique_constraint(:token_hash)
  end
end
