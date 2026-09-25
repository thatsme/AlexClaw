defmodule AlexClaw.LLM.ProviderSecrets do
  @moduledoc """
  An LLM provider's API key and header values, kept in OpenBao as secrets the
  provider owns (`AlexClaw.Secrets.Owned`); the row's `credentials` holds the
  references: `%{"api_key" => ref, "headers" => %{header => ref}}` (0.4.0 S7).

  They are bound to the host the provider's calls go to: its `host` for an
  OpenAI-compatible, Ollama or custom provider, Google's or Anthropic's API
  host for those types. A key with no host to bind to is refused. A header's
  name stays readable; its value is a secret whatever the header is, since a
  form cannot tell a credential header from any other.

  A save is given the key and the headers (`Provider`'s virtual fields): a
  blank key keeps the stored one, as does a header given blank; headers not
  given at all are all kept; a header left out of a given set is dropped.
  Moving the provider to another host with a key kept is refused: the key
  must be entered again for the new host. Each call resolves the values for
  that host (`resolved/1`); every use is audited by `AlexClaw.Secrets`.
  """
  alias AlexClaw.LLM.Provider
  alias AlexClaw.Secrets
  alias AlexClaw.Secrets.Owned

  @fixed_hosts %{
    "gemini" => "host:generativelanguage.googleapis.com",
    "anthropic" => "host:api.anthropic.com"
  }

  @doc "The destination a provider's credentials are bound to, or nil."
  @spec destination(String.t() | nil, String.t() | nil) :: String.t() | nil
  def destination(type, _host) when is_map_key(@fixed_hosts, type), do: @fixed_hosts[type]
  def destination(_type, host), do: Owned.url_binding(host)

  @doc "The secrets `credentials` references, as path => name."
  @spec references(map() | nil) :: %{Owned.path() => String.t()}
  def references(credentials) when is_map(credentials) do
    headers =
      for {name, ref} <- Map.get(credentials, "headers", %{}), do: {["headers", name], ref}

    [{["api_key"], Map.get(credentials, "api_key")} | headers]
    |> Enum.filter(fn {_path, ref} -> Owned.reference?(ref) end)
    |> Map.new(fn {path, %{"secret" => name}} -> {path, name} end)
  end

  def references(_none), do: %{}

  @doc """
  Plan the credentials of a provider being saved from `changeset` against
  the ones it held (`old`). Returns the changeset with `credentials` holding
  references and what to store and delete, or the changeset with an error.
  """
  @spec plan(Ecto.Changeset.t(), map() | nil) ::
          {:ok, Ecto.Changeset.t(), Owned.secrets()} | {:error, Ecto.Changeset.t()}
  def plan(%Ecto.Changeset{valid?: false} = changeset, _old), do: {:error, changeset}

  def plan(changeset, old) do
    old = old || %{}
    host = destination(field(changeset, :type), field(changeset, :host))

    changeset
    |> fields(old)
    |> Owned.plan(references(old), host, &Owned.name("provider", &1))
    |> planned(changeset, host)
  end

  defp planned({:ok, plan, dropped}, changeset, host) do
    credentials = Owned.referenced(%{"headers" => %{}}, plan)

    {:ok,
     changeset
     |> Ecto.Changeset.put_change(:credentials, credentials)
     |> Ecto.Changeset.delete_change(:api_key)
     |> Ecto.Changeset.delete_change(:headers), {plan, host, dropped}}
  end

  defp planned({:error, reason}, changeset, _host),
    do: {:error, Ecto.Changeset.add_error(changeset, :api_key, reason)}

  defp field(changeset, name), do: Ecto.Changeset.get_field(changeset, name)

  # What the save means for each credential: a value to store, the reference
  # kept, or nothing.
  defp fields(changeset, old) do
    Map.merge(
      %{["api_key"] => given_or_kept(field(changeset, :api_key), Map.get(old, "api_key"))},
      header_fields(field(changeset, :headers), Map.get(old, "headers", %{}))
    )
  end

  defp header_fields(nil, old_headers),
    do: Map.new(old_headers, fn {name, ref} -> {["headers", name], ref} end)

  defp header_fields(headers, old_headers) when is_map(headers),
    do:
      Map.new(headers, fn {name, value} ->
        {["headers", to_string(name)],
         given_or_kept(value, Map.get(old_headers, to_string(name)))}
      end)

  defp given_or_kept(value, old) when value in [nil, ""], do: old
  defp given_or_kept(value, _old), do: value

  @doc "Save `changeset` with its planned credentials (`Owned.saved/4`)."
  @spec saved(Ecto.Changeset.t(), Owned.secrets(), (Ecto.Changeset.t() ->
                                                      {:ok, Provider.t()} | {:error, term()})) ::
          {:ok, Provider.t()} | {:error, term()}
  def saved(changeset, secrets, persist), do: Owned.saved(changeset, secrets, &kind/1, persist)

  defp kind(["api_key"]), do: "api_token"
  defp kind(_header), do: "other"

  @doc "Delete the secrets a provider references."
  @spec delete(Provider.t()) :: :ok
  def delete(%Provider{credentials: credentials}),
    do: credentials |> references() |> Map.values() |> Owned.delete()

  @doc """
  The provider's API key and headers, resolved for the host its calls go to:
  `{:ok, api_key | nil, [{header, value}]}`, or the first failure.
  """
  @spec resolved(Provider.t()) ::
          {:ok, String.t() | nil, [{String.t(), String.t()}]} | {:error, term()}
  def resolved(%Provider{type: type, host: host, credentials: credentials}) do
    destination = destination(type, host)

    credentials
    |> references()
    |> Enum.reduce_while({:ok, nil, []}, fn {path, name}, acc ->
      name |> resolve(destination) |> with_value(path, acc)
    end)
  end

  defp resolve(_name, nil), do: {:error, :no_destination}
  defp resolve(name, destination), do: Secrets.resolve(name, for: destination)

  defp with_value({:ok, value}, ["api_key"], {:ok, _key, headers}),
    do: {:cont, {:ok, value, headers}}

  defp with_value({:ok, value}, ["headers", name], {:ok, key, headers}),
    do: {:cont, {:ok, key, [{name, value} | headers]}}

  defp with_value({:error, reason}, path, _acc),
    do: {:halt, {:error, {:secret, List.last(path), reason}}}
end
