defmodule AlexClaw.MCP.Key do
  @moduledoc """
  The MCP key: recognised, never retrievable.

  AlexClaw never needs the key itself, only to recognise it, so it keeps it the
  way a password is kept:

    * `generate/0` makes a random key and returns it once; nothing can show it
      again;
    * what is stored (the `mcp.api_key` setting) is its fingerprint: an HMAC
      computed by OpenBao's transit engine with a key AlexClaw never holds, so a
      copy of the database holds nothing that can be turned back into the key
      or tried offline;
    * `valid?/1` computes the fingerprint of a presented token and compares it
      with the stored one in constant time;
    * a new key replaces the old one at once; `revoke/0` leaves none, and the
      MCP endpoint then refuses everything.
  """

  alias AlexClaw.{Config, Vault}

  @key "mcp.api_key"
  @bytes 32

  @doc """
  Make a new key, store its fingerprint, and return the key. It is shown once.
  The row is written, not published: performed as `:generate_mcp_key`, the
  publish follows the commit (`AlexClaw.ControlPlane.Actions.after_commit/4`).
  The fingerprint is read from the database, so the key is valid at once.
  """
  @spec generate() :: {:ok, String.t()} | {:error, term()}
  def generate do
    key = @bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    with {:ok, fingerprint} <- fingerprint_of(key),
         {:ok, _setting} <-
           Config.persist(@key, fingerprint,
             category: "mcp",
             description: "MCP key fingerprint (the key itself is shown once, never stored)"
           ) do
      {:ok, key}
    end
  end

  @doc "Whether `token` is the current key."
  @spec valid?(term()) :: boolean()
  def valid?(token) when is_binary(token) and token != "", do: matching(fingerprint(), token)
  def valid?(_token), do: false

  @doc "Remove the key: nothing is recognised until a new one is generated."
  @spec revoke() :: :ok | {:error, term()}
  def revoke, do: Config.clear(@key)

  @doc "The stored fingerprint, or nil when no key is set."
  @spec fingerprint() :: String.t() | nil
  def fingerprint, do: Config.fingerprint(@key)

  @doc """
  The fingerprint of `value`, in the form stored for the MCP key.

  Options: `vault:` — the `AlexClaw.Vault` server to use.
  """
  @spec fingerprint_of(String.t(), keyword()) :: {:ok, String.t()} | {:error, Vault.error()}
  def fingerprint_of(value, opts \\ []) do
    with {:ok, hmac} <- Vault.hmac(value, server: Keyword.get(opts, :vault, Vault)),
         do: {:ok, Config.fingerprint_prefix() <> hmac}
  end

  # No key set: nothing to compare with, and OpenBao is not asked.
  defp matching(nil, _token), do: false
  defp matching(stored, token), do: matches?(stored, fingerprint_of(token))

  defp matches?(stored, {:ok, presented}), do: Plug.Crypto.secure_compare(stored, presented)
  defp matches?(_stored, {:error, _reason}), do: false
end
