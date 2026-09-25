defmodule AlexClaw.Config.SecretSettings do
  @moduledoc """
  The settings that are secrets, each with the destination it may be used for.

  A declared-secret setting keeps no value in the settings table: its value
  lives in OpenBao as the secret `setting_<key with dots as underscores>`,
  catalogued by `AlexClaw.Secrets` and bound as declared here. The settings row
  stays, with no value, so forms can show the setting and when it was last set.

  A binding may depend on configuration — the Telegram token is bound to the
  host of the Telegram API the gateway actually uses — so it is resolved when
  asked, not fixed at compile time.
  """

  alias AlexClaw.Secrets

  @declared %{
    "telegram.bot_token" => %{
      kind: "bot_token",
      binding: {:host_of, :telegram_api_base, "https://api.telegram.org"}
    }
  }

  @doc "Whether `key` is a declared-secret setting."
  @spec secret?(String.t()) :: boolean()
  def secret?(key), do: Map.has_key?(@declared, key)

  @doc "Every declared-secret key."
  @spec keys() :: [String.t()]
  def keys, do: Map.keys(@declared)

  @doc "The catalogue name of the secret behind `key`."
  @spec secret_name(String.t()) :: String.t()
  def secret_name(key), do: "setting_" <> String.replace(key, ".", "_")

  @doc "The kind of secret `key` holds (see `AlexClaw.Secrets.Secret.kinds/0`)."
  @spec kind(String.t()) :: String.t()
  def kind(key), do: Map.fetch!(@declared, key).kind

  @doc "The destination `key`'s value may be used for, as a binding."
  @spec binding_for(String.t()) :: String.t()
  def binding_for(key), do: key |> declared_binding() |> resolved()

  @doc """
  Store `value` as the secret behind `key`: catalogued on first use (named and
  bound as declared), then written to OpenBao, which stamps when it was set.
  """
  @spec store(String.t(), String.t()) :: :ok | {:error, Ecto.Changeset.t() | Secrets.error()}
  def store(key, value) do
    name = secret_name(key)

    with :ok <- catalogued(Secrets.get(name), key, name), do: Secrets.put_value(name, value)
  end

  defp catalogued(nil, key, name) do
    %{
      name: name,
      description: "The #{key} setting",
      kind: kind(key),
      binding: [binding_for(key)]
    }
    |> Secrets.define()
    |> defined()
  end

  defp catalogued(_secret, _key, _name), do: :ok

  defp defined({:ok, _secret}), do: :ok
  defp defined({:error, _changeset} = error), do: error

  defp declared_binding(key), do: Map.fetch!(@declared, key).binding

  defp resolved({:host_of, app_key, default}) do
    %URI{host: host} = URI.parse(Application.get_env(:alex_claw, app_key, default))
    "host:" <> host
  end
end
