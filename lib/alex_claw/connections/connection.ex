defmodule AlexClaw.Connections.Connection do
  @moduledoc """
  A database connection an admin defined: a PostgreSQL server and how to
  reach it.

  The password is a secret in OpenBao bound to `connection:<name>`
  (`AlexClaw.Connections.ConnectionSecrets`); `credentials` holds its
  reference. `password` is what a save is given, planned into that reference
  before the row is written: it is never stored. The name is the binding, so
  it is a short lowercase identifier and never changes. The host is never
  AlexClaw itself or one of its own services
  (`AlexClaw.Connections.Target`). The TLS mode has no default:

    * `disable` — no TLS: the password is readable on the network path;
    * `require` — encrypted, the server's identity not verified: a server
      that impersonates the real one can ask for the password in clear and
      receive it (Postgrex cannot be made to insist on SCRAM);
    * `verify_full` — encrypted, the certificate verified against the
      system's CAs and the host name checked.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias AlexClaw.Connections.Target

  @type t :: %__MODULE__{}

  @tls_modes ~w(disable require verify_full)
  @fields [:name, :host, :port, :database, :username, :tls_mode, :password]
  @required [:name, :host, :port, :database, :username, :tls_mode]

  schema "db_connections" do
    field(:name, :string)
    field(:host, :string)
    field(:port, :integer)
    field(:database, :string)
    field(:username, :string)
    field(:tls_mode, :string)
    field(:password, :string, virtual: true, redact: true)
    field(:credentials, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @doc "The TLS modes a connection may use."
  @spec tls_modes() :: [String.t()]
  def tls_modes, do: @tls_modes

  @doc "A new connection."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{id: nil} = conn, attrs) do
    conn
    |> cast_fields(attrs)
    |> validated()
  end

  # An existing one: everything but the name, which is its secret's binding.
  def changeset(%__MODULE__{} = conn, attrs) do
    conn
    |> cast_fields(attrs)
    |> fixed_name(conn)
    |> validated()
  end

  # A blank password is kept as given — it means "keep the stored one" — and
  # every other blank field is missing.
  defp cast_fields(conn, attrs) do
    conn
    |> cast(attrs, @fields -- [:password])
    |> cast(attrs, [:password], empty_values: [])
  end

  defp fixed_name(changeset, %{name: name}) do
    case fetch_change(changeset, :name) do
      {:ok, ^name} -> delete_change(changeset, :name)
      {:ok, _other} -> add_error(changeset, :name, "cannot be changed")
      :error -> changeset
    end
  end

  defp validated(changeset) do
    changeset
    |> validate_required(@required)
    |> validate_format(:name, ~r/\A[a-z0-9_]{1,40}\z/,
      message: "use 1 to 40 lowercase letters, digits and underscores"
    )
    |> validate_inclusion(:tls_mode, @tls_modes,
      message: "choose one of #{Enum.join(@tls_modes, ", ")}"
    )
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_length(:host, max: 253)
    |> validate_change(:host, &customer_host/2)
    |> unique_constraint(:name)
  end

  # Never AlexClaw itself or one of its own services (Target).
  defp customer_host(:host, host) do
    case Target.check(host) do
      :ok -> []
      {:error, reason} -> [host: reason]
    end
  end
end
