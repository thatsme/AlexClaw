defmodule AlexClaw.Connections do
  @moduledoc """
  Database connections: the PostgreSQL servers `sql_query` steps read from,
  defined in the admin UI through the control plane (2FA elevation,
  audited). There is no default connection and no fallback to AlexClaw's own
  database: a connection exists only once an admin has defined it.

  A connection's password is a secret in OpenBao, bound to the connection
  (`AlexClaw.Connections.ConnectionSecrets`). These functions touch the
  database and OpenBao only; the running pools follow the definitions
  through `AlexClaw.Connections.Pools.sync/1`, which the control plane calls
  once a change has committed.
  """
  import Ecto.Query

  alias AlexClaw.Connections.{Connection, ConnectionSecrets}
  alias AlexClaw.Repo
  alias AlexClaw.Workflows.WorkflowStep

  @doc "Every defined connection, by name."
  @spec list_connections() :: [Connection.t()]
  def list_connections, do: Repo.all(from(c in Connection, order_by: c.name))

  @doc "The connection with `id`."
  @spec get_connection(integer() | String.t()) :: {:ok, Connection.t()} | {:error, :not_found}
  def get_connection(id), do: found(Repo.get(Connection, id))

  @doc "The connection named `name`."
  @spec get_by_name(String.t()) :: {:ok, Connection.t()} | {:error, :not_found}
  def get_by_name(name) when is_binary(name), do: found(Repo.get_by(Connection, name: name))

  defp found(nil), do: {:error, :not_found}
  defp found(conn), do: {:ok, conn}

  @doc "Define a connection; its password goes to OpenBao."
  @spec create_connection(map()) :: {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def create_connection(attrs) do
    %Connection{}
    |> Connection.changeset(attrs)
    |> saved(nil, &Repo.insert/1)
  end

  @doc """
  Change a connection. A blank password keeps the stored one, except when the
  connection points at another server: then it must be entered again.
  """
  @spec update_connection(Connection.t(), map()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def update_connection(%Connection{} = conn, attrs) do
    conn
    |> Connection.changeset(attrs)
    |> saved(conn, &Repo.update/1)
  end

  defp saved(changeset, old, persist) do
    with {:ok, changeset, secrets} <- ConnectionSecrets.plan(changeset, old),
         do: ConnectionSecrets.saved(changeset, secrets, persist)
  end

  @doc """
  Remove a connection, then its secret. Refused while a workflow step uses
  it, naming the workflows.
  """
  @spec delete_connection(Connection.t()) ::
          {:ok, Connection.t()} | {:error, {:in_use, [String.t()]} | Ecto.Changeset.t()}
  def delete_connection(%Connection{} = conn) do
    with :ok <- unused(users(conn.name)),
         {:ok, deleted} <- Repo.delete(conn) do
      ConnectionSecrets.delete(deleted)
      {:ok, deleted}
    end
  end

  defp unused([]), do: :ok
  defp unused(workflows), do: {:error, {:in_use, workflows}}

  @doc "The names of the workflows with a `sql_query` step on the connection `name`."
  @spec users(String.t()) :: [String.t()]
  def users(name) do
    from(s in WorkflowStep,
      join: w in assoc(s, :workflow),
      where: s.skill == "sql_query" and fragment("?->>'connection'", s.config) == ^name,
      distinct: true,
      select: w.name,
      order_by: w.name
    )
    |> Repo.all()
  end
end
