defmodule AlexClaw.Database.KeyCheck do
  @moduledoc """
  Whether an export's encrypted values decrypt under the running
  `SECRET_KEY_BASE`. The sensitive settings and the credentials stored outside
  them (`AlexClaw.Encrypted`) are exported as they are stored, encrypted; a
  file made under another key would restore values nothing can read, the TOTP
  secret among them, so a restore refuses it before anything changes.
  """

  alias AlexClaw.Encrypted

  # {table, column} => how the column's text form holds encrypted strings
  @encrypted %{
    {"settings", "value"} => :text,
    {"llm_providers", "api_key"} => :text,
    {"llm_providers", "headers"} => :json,
    {"workflow_steps", "config"} => :json
  }

  @doc "The columns that hold encrypted values."
  @spec columns() :: %{{String.t(), String.t()} => :text | :json}
  def columns, do: @encrypted

  @doc "Check one exported row of `table`, whose columns are `names`."
  @spec check(String.t(), [String.t()], [String.t() | nil]) :: :ok | {:error, String.t()}
  def check(table, names, row) do
    names
    |> Enum.zip(row)
    |> Enum.all?(fn {name, value} -> decrypts?(Map.get(@encrypted, {table, name}), value) end)
    |> checked()
  end

  defp decrypts?(nil, _value), do: true
  defp decrypts?(_kind, nil), do: true
  defp decrypts?(:text, value), do: Encrypted.decryptable?(value)
  defp decrypts?(:json, value), do: value |> Jason.decode() |> json_decrypts?()

  # Not JSON: nothing encrypted to check. The column's own type refuses it.
  defp json_decrypts?({:ok, decoded}), do: Encrypted.decryptable?(decoded)
  defp json_decrypts?({:error, _}), do: true

  defp checked(true), do: :ok

  defp checked(false),
    do: {:error, "an encrypted value does not decrypt under this SECRET_KEY_BASE"}
end
