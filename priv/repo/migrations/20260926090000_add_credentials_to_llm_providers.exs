defmodule AlexClaw.Repo.Migrations.AddCredentialsToLlmProviders do
  @moduledoc """
  A provider's credentials become references to secrets in OpenBao (0.4.0 S7):
  `credentials` holds `%{"api_key" => %{"secret" => name}, "headers" =>
  %{header => %{"secret" => name}}}`. The `api_key` and `headers` columns keep
  what 0.3.x stored there, encrypted, until the boot upgrade moves it; the
  schema no longer maps them. Nullable, so an export from before this column
  still restores.
  """
  use Ecto.Migration

  def change do
    alter table(:llm_providers) do
      add(:credentials, :map, default: %{})
    end
  end
end
