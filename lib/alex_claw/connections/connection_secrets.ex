defmodule AlexClaw.Connections.ConnectionSecrets do
  @moduledoc """
  A connection's password, kept in OpenBao as a secret the connection owns
  (`AlexClaw.Secrets.Owned`), of kind `database_password`, bound to
  `connection:<name>`. The row's `credentials` holds the reference:
  `%{"password" => %{"secret" => name}}`.

  A new connection needs a password. On an edit a blank password keeps the
  stored one — unless the connection now points at another server (host,
  port, database, user or TLS mode): the binding is the name, which does not
  change, so the password a server was given must be entered again before it
  is sent to another. Each connect resolves it (`resolve/1`); every use is
  audited by `AlexClaw.Secrets`.
  """
  alias AlexClaw.Connections.Connection
  alias AlexClaw.Secrets
  alias AlexClaw.Secrets.Owned

  @path ["password"]
  @server [:host, :port, :database, :username, :tls_mode]

  @doc "The binding of the connection named `name`."
  @spec destination(String.t()) :: String.t()
  def destination(name), do: "connection:" <> name

  @doc "The name of the secret holding the connection's password, or nil."
  @spec secret_name(Connection.t()) :: String.t() | nil
  def secret_name(%Connection{credentials: %{"password" => %{"secret" => name}}}), do: name
  def secret_name(_conn), do: nil

  @doc """
  Plan the password of a connection being saved from `changeset` against the
  connection as it was (`old`, nil for a new one). Returns the changeset with
  `credentials` holding the reference and what to store and delete, or the
  changeset with an error.
  """
  @spec plan(Ecto.Changeset.t(), Connection.t() | nil) ::
          {:ok, Ecto.Changeset.t(), Owned.secrets()} | {:error, Ecto.Changeset.t()}
  def plan(changeset, old) do
    case planned_for(changeset, old) do
      {:ok, _changeset, _secrets} = ok -> ok
      # A refused save keeps no trace of the password it was given.
      {:error, refused} -> {:error, Ecto.Changeset.delete_change(refused, :password)}
    end
  end

  defp planned_for(%Ecto.Changeset{valid?: false} = changeset, _old), do: {:error, changeset}

  defp planned_for(changeset, old) do
    given = Ecto.Changeset.get_change(changeset, :password)

    with :ok <- password_needed(given, old, changeset) do
      destination = destination(Ecto.Changeset.get_field(changeset, :name))

      %{@path => given_or_kept(given, old)}
      |> Owned.plan(references(old), destination, &Owned.name("connection", &1))
      |> planned(changeset, destination)
    end
  end

  # A blank password is a keep: nothing to keep on a new connection, and not
  # for another server.
  defp password_needed(given, nil, changeset) when given in [nil, ""],
    do: {:error, Ecto.Changeset.add_error(changeset, :password, "can't be blank")}

  defp password_needed(given, _old, changeset) when given in [nil, ""] do
    case Enum.any?(@server, &Map.has_key?(changeset.changes, &1)) do
      true ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :password,
           "must be entered again for the new server"
         )}

      false ->
        :ok
    end
  end

  defp password_needed(_given, _old, _changeset), do: :ok

  defp given_or_kept(given, old) when given in [nil, ""], do: reference(old)
  defp given_or_kept(given, _old), do: given

  defp reference(nil), do: nil
  defp reference(%Connection{credentials: credentials}), do: Map.get(credentials, "password")

  defp references(nil), do: %{}

  defp references(conn) do
    case secret_name(conn) do
      nil -> %{}
      name -> %{@path => name}
    end
  end

  defp planned({:ok, plan, dropped}, changeset, destination) do
    {:ok,
     changeset
     |> Ecto.Changeset.put_change(:credentials, Owned.referenced(%{}, plan))
     |> Ecto.Changeset.delete_change(:password), {plan, destination, dropped}}
  end

  defp planned({:error, reason}, changeset, _destination),
    do: {:error, Ecto.Changeset.add_error(changeset, :password, reason)}

  @doc "Save `changeset` with its planned password (`Owned.saved/4`)."
  @spec saved(Ecto.Changeset.t(), Owned.secrets(), (Ecto.Changeset.t() ->
                                                      {:ok, Connection.t()} | {:error, term()})) ::
          {:ok, Connection.t()} | {:error, term()}
  def saved(changeset, secrets, persist),
    do: Owned.saved(changeset, secrets, fn _path -> "database_password" end, persist)

  @doc "Delete the secret a connection references."
  @spec delete(Connection.t()) :: :ok
  def delete(conn), do: conn |> references() |> Map.values() |> Owned.delete()

  @doc """
  The connection's password, resolved for its binding now: nothing keeps it.
  The error names the reason, never a value.
  """
  @spec resolve(Connection.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(%Connection{name: name} = conn) do
    case secret_name(conn) do
      nil -> {:error, :no_password}
      secret -> Secrets.resolve(secret, for: destination(name))
    end
  end
end
