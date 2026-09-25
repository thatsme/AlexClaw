defmodule AlexClaw.Secrets.Secret do
  @moduledoc """
  One entry of the secrets catalogue: a name, what it is, and the destinations
  it may be used for. Never a value — see `AlexClaw.Secrets`.

  A binding is one of:
    * `host:<hostname>` — sent to that host;
    * `connection:<name>` — a configured database connection;
    * `origin:<scheme>://<host>[:<port>]` — a web origin (a login a recipe types);
    * `inbound:<receiver>` — checked by AlexClaw itself on a request it
      receives (a webhook signature), never sent anywhere.

  Bindings are matched exactly, so `host:api.github.com` does not cover a
  subdomain or a longer name.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @kinds ~w(database_password api_token bot_token oauth_secret login other)
  @binding_forms [
    ~r/^host:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/,
    ~r/^connection:[A-Za-z0-9_.-]+$/,
    ~r/^origin:https?:\/\/[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::\d{1,5})?$/,
    ~r/^inbound:[a-z0-9_]+$/
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          kind: String.t(),
          binding: [String.t()],
          rotated_at: DateTime.t() | nil
        }

  schema "secrets" do
    field(:name, :string)
    field(:description, :string)
    field(:kind, :string)
    field(:binding, {:array, :string})
    field(:rotated_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @doc "The kinds a secret may be."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Changeset for defining a secret. A `value` in `attrs` is refused."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:name, :description, :kind, :binding])
    |> validate_required([:name, :kind, :binding])
    |> validate_format(:name, ~r/^[a-z0-9_]{2,64}$/,
      message: "must be 2 to 64 lower-case letters, digits or underscores"
    )
    |> validate_inclusion(:kind, @kinds)
    |> validate_binding()
    |> refuse_value(attrs)
    |> unique_constraint(:name)
  end

  @doc "Stamp the time a value was set."
  @spec rotated(t()) :: Ecto.Changeset.t()
  def rotated(secret), do: change(secret, rotated_at: DateTime.utc_now(:second))

  defp validate_binding(changeset) do
    validate_change(changeset, :binding, fn :binding, binding -> binding_errors(binding) end)
  end

  defp binding_errors([]), do: [binding: "must name at least one destination"]

  defp binding_errors(binding) do
    case Enum.reject(binding, &known_form?/1) do
      [] -> []
      bad -> [binding: "not host:, connection:, origin: or inbound: — #{Enum.join(bad, ", ")}"]
    end
  end

  defp known_form?(destination) when is_binary(destination),
    do: Enum.any?(@binding_forms, &Regex.match?(&1, destination))

  defp known_form?(_destination), do: false

  # A value is never an attribute of the catalogue: it goes to OpenBao through
  # AlexClaw.Secrets.put_value/2.
  defp refuse_value(changeset, attrs) do
    if Map.has_key?(attrs, :value) or Map.has_key?(attrs, "value"),
      do: add_error(changeset, :value, "is never stored here: set it with put_value/2"),
      else: changeset
  end
end
