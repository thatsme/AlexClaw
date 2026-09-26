defmodule AlexClaw.Config.SecretSettings do
  @moduledoc """
  The settings that are secrets, each with the destinations it may be used for.

  A declared-secret setting keeps no value in the settings table: its value
  lives in OpenBao as the secret `setting_<key with dots as underscores>`,
  catalogued by `AlexClaw.Secrets` and bound as declared here. The settings row
  stays, with no value, so forms can show the setting and when it was last set.

  A binding may depend on configuration — the Telegram token is bound to the
  host of the Telegram API the gateway actually uses — so bindings are resolved
  when asked, not fixed at compile time.

  `mcp.api_key` is declared too, but it is recognised, never retrieved: it has
  no value anywhere, only a fingerprint (`AlexClaw.MCP.Key`).
  """

  alias AlexClaw.Secrets

  @google_oauth {:host, "oauth2.googleapis.com"}

  @declared %{
    "telegram.bot_token" => %{
      kind: "bot_token",
      bindings: [{:host_of, :telegram_api_base, "https://api.telegram.org"}]
    },
    "github.token" => %{
      kind: "api_token",
      bindings: [{:host_of, :github_api_base, "https://api.github.com"}]
    },
    "llm.anthropic_api_key" => %{kind: "api_token", bindings: [{:host, "api.anthropic.com"}]},
    "llm.gemini_api_key" => %{
      kind: "api_token",
      bindings: [
        {:host, "generativelanguage.googleapis.com"},
        {:host_of_when_set, :embedding_base_url}
      ]
    },
    "google.oauth.client_secret" => %{kind: "oauth_secret", bindings: [@google_oauth]},
    "google.oauth.refresh_token" => %{kind: "oauth_secret", bindings: [@google_oauth]},
    "discord.bot_token" => %{
      kind: "bot_token",
      bindings: [{:host, "discord.com"}, {:host, "gateway.discord.gg"}]
    },
    "github.webhook_secret" => %{kind: "other", bindings: [{:inbound, "github_webhook"}]},
    "mcp.api_key" => %{kind: "api_token", bindings: [], recognised_only: true}
  }

  @doc "Whether `key` is a declared-secret setting."
  @spec secret?(String.t()) :: boolean()
  def secret?(key), do: Map.has_key?(@declared, key)

  @doc "Every declared-secret key."
  @spec keys() :: [String.t()]
  def keys, do: Map.keys(@declared)

  @doc """
  Whether `key` is recognised, never retrieved: it has no value, only a
  fingerprint (`mcp.api_key`).
  """
  @spec recognised_only?(String.t()) :: boolean()
  def recognised_only?(key), do: Map.get(@declared[key] || %{}, :recognised_only, false)

  @doc "The catalogue name of the secret behind `key`."
  @spec secret_name(String.t()) :: String.t()
  def secret_name(key), do: "setting_" <> String.replace(key, ".", "_")

  @doc "The kind of secret `key` holds (see `AlexClaw.Secrets.Secret.kinds/0`)."
  @spec kind(String.t()) :: String.t()
  def kind(key), do: Map.fetch!(@declared, key).kind

  @doc "Every destination `key`'s value may be used for, as bindings."
  @spec bindings_for(String.t()) :: [String.t()]
  def bindings_for(key) do
    @declared
    |> Map.fetch!(key)
    |> Map.fetch!(:bindings)
    |> Enum.flat_map(&resolved/1)
    |> Enum.uniq()
  end

  @doc "The one destination of a single-binding key. Raises for any other key."
  @spec binding_for(String.t()) :: String.t()
  def binding_for(key) do
    case bindings_for(key) do
      [binding] -> binding
      bindings -> raise ArgumentError, "#{key} has #{length(bindings)} bindings, not one"
    end
  end

  @doc """
  Store `value` as the secret behind `key`: catalogued on first use (named and
  bound as declared), then written to OpenBao, which stamps when it was set.

  Options: `vault:` — the `AlexClaw.Vault` server to use.
  """
  @spec store(String.t(), String.t(), keyword()) ::
          :ok | {:error, Ecto.Changeset.t() | Secrets.error()}
  def store(key, value, opts \\ []) do
    name = secret_name(key)

    with :ok <- catalogued(Secrets.get(name), key, name),
         do: Secrets.put_value(name, value, opts)
  end

  @doc """
  Store `value` as the secret behind `key` only if it holds none yet
  (`AlexClaw.Secrets.put_new_value/3`): what the 0.4.0 upgrade moves, which
  never replaces a value entered since. Another value there is
  `{:error, :conflict}`.
  """
  @spec store_new(String.t(), String.t(), keyword()) ::
          :ok | {:error, :conflict | Ecto.Changeset.t() | Secrets.error()}
  def store_new(key, value, opts \\ []) do
    name = secret_name(key)

    with :ok <- catalogued(Secrets.get(name), key, name),
         do: Secrets.put_new_value(name, value, opts)
  end

  defp catalogued(nil, key, name) do
    %{name: name, description: "The #{key} setting", kind: kind(key), binding: bindings_for(key)}
    |> Secrets.define()
    |> defined()
  end

  defp catalogued(_secret, _key, _name), do: :ok

  defp defined({:ok, _secret}), do: :ok
  defp defined({:error, _changeset} = error), do: error

  defp resolved({:host, host}), do: ["host:" <> host]
  defp resolved({:inbound, receiver}), do: ["inbound:" <> receiver]
  defp resolved({:host_of, app_key, default}), do: [host_binding(app_env(app_key, default))]

  defp resolved({:host_of_when_set, app_key}),
    do: app_key |> app_env(nil) |> optional_host_binding()

  defp optional_host_binding(nil), do: []
  defp optional_host_binding(url), do: [host_binding(url)]

  defp app_env(app_key, default), do: Application.get_env(:alex_claw, app_key, default)

  defp host_binding(url) do
    %URI{host: host} = URI.parse(url)
    "host:" <> host
  end
end
