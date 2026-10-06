defmodule AlexClaw.Connections.ConnectionSecrets do
  @moduledoc """
  A connection's password, kept in OpenBao as a secret the connection owns
  (`AlexClaw.Secrets.Owned`), of kind `database_password`. The row's
  `credentials` holds the reference: `%{"password" => %{"secret" => name}}`.

  The secret is bound to the server it was entered for:
  `connection:<name>.<fingerprint>`, the fingerprint a digest of the host,
  port, database, user and TLS mode. A row whose server differs from the one
  the password was entered for — changed by a save, a restore or any other
  write — does not resolve it. A new connection needs a password; on an edit
  a blank password keeps the stored one only while the server is the same.
  Each connect resolves it (`resolve/1`); every use is audited by
  `AlexClaw.Secrets`.

  Its rotation notice is sent once the save has committed
  (`AlexClaw.Secrets.notify_after/1`), never while the change can still be
  undone.
  """
  alias AlexClaw.Connections.Connection
  alias AlexClaw.Secrets
  alias AlexClaw.Secrets.Owned

  @path ["password"]
  @server [:host, :port, :database, :username, :tls_mode]

  @doc """
  The binding of a connection's password: its name and a fingerprint of its
  server. `connection` is anything with the connection's fields (a
  `Connection`, or a map with the same keys); the host's case does not count.
  """
  @spec destination(map()) :: String.t()
  def destination(%{name: name} = connection),
    do: "connection:" <> name <> "." <> fingerprint(connection)

  defp fingerprint(%{host: host, port: port, database: database, username: user, tls_mode: tls}) do
    [String.downcase(host), to_string(port), database, user, tls]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

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
      destination = changeset |> server_fields() |> destination()

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

  defp server_fields(changeset),
    do: Map.new([:name | @server], &{&1, Ecto.Changeset.get_field(changeset, &1)})

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

  @doc """
  Save `changeset` with its planned password (`Owned.saved/5`); the rotation
  notice waits for the commit.
  """
  @spec saved(Ecto.Changeset.t(), Owned.secrets(), (Ecto.Changeset.t() ->
                                                      {:ok, Connection.t()} | {:error, term()})) ::
          {:ok, Connection.t()} | {:error, term()}
  def saved(changeset, secrets, persist),
    do:
      Owned.saved(changeset, secrets, fn _path -> "database_password" end, persist,
        notice: :after_commit
      )

  @doc "Delete the secret a connection references."
  @spec delete(Connection.t()) :: :ok
  def delete(conn), do: conn |> references() |> Map.values() |> Owned.delete()

  @doc """
  The connection's password, resolved now for the server the row names:
  nothing keeps it. `{:error, :not_bound}` when that is not the server the
  password was entered for. The error names the reason, never a value.
  """
  @spec resolve(Connection.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(%Connection{} = conn) do
    case secret_name(conn) do
      nil -> {:error, :no_password}
      secret -> Secrets.resolve(secret, for: destination(conn))
    end
  end
end
