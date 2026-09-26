defmodule AlexClaw.Secrets do
  @moduledoc """
  The secrets layer: a catalogue in AlexClaw's database, the values in OpenBao.

  The catalogue (`AlexClaw.Secrets.Secret`) holds what AlexClaw may know about
  a secret — its name, description, kind, the destinations it is bound to, and
  when its value was last set. It never holds a value. Each value lives in
  OpenBao at `secret/alexclaw/secrets/<name>`, as `{"value": ...}`.

  `resolve/2` is the only way code gets a value. It refuses a destination the
  secret is not bound to, reads the value from OpenBao at that moment (nothing
  caches it), and records every attempt in the audit log — the secret's name,
  the destination and the outcome, never the value. Setting a value
  (`put_value/2`) is audited the same way.
  """
  import Ecto.Query

  alias AlexClaw.Auth.AuditLog
  alias AlexClaw.Repo
  alias AlexClaw.Secrets.{Mask, Secret}
  alias AlexClaw.Vault

  @type error ::
          :unknown_secret
          | :not_bound
          | :no_value
          | :empty_value
          | :malformed_value
          | Vault.error()

  @topic "secrets"

  @doc """
  The PubSub topic on which a secret's rotation or removal is announced, as
  `{:secret_rotated, name}` — the name, never the value — so a consumer that
  holds a value knows to resolve it again.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Define a secret: name, description, kind, binding. Never a value. Audited."
  @spec define(map()) :: {:ok, Secret.t()} | {:error, Ecto.Changeset.t()}
  def define(attrs) do
    changeset = Secret.changeset(%Secret{}, attrs)
    result = Repo.insert(changeset)

    AuditLog.log_secret_define(
      to_string(Ecto.Changeset.get_field(changeset, :name)),
      Ecto.Changeset.get_field(changeset, :binding) || [],
      catalogued(result)
    )

    result
  end

  @doc """
  Bind the secret `name` to `binding` instead of what it was bound to: a
  credential re-entered for a new destination. The value is not touched.
  Audited.
  """
  @spec rebind(String.t(), [String.t()]) :: :ok | {:error, Ecto.Changeset.t() | :unknown_secret}
  def rebind(name, binding) do
    result = name |> get() |> rebound(binding)
    AuditLog.log_secret_rebind(name, binding, catalogued(result))
    result
  end

  defp rebound(nil, _binding), do: {:error, :unknown_secret}

  defp rebound(secret, binding),
    do: secret |> Secret.changeset(%{binding: binding}) |> Repo.update() |> rebound()

  defp rebound({:ok, _secret}), do: :ok
  defp rebound({:error, _changeset} = error), do: error

  # A catalogue change refused by its changeset is audited as :invalid, never
  # the changeset itself.
  defp catalogued({:error, %Ecto.Changeset{}}), do: {:error, :invalid}
  defp catalogued(result), do: outcome(result)

  @doc "The catalogue entry named `name`, or nil."
  @spec get(String.t()) :: Secret.t() | nil
  def get(name) when is_binary(name), do: Repo.get_by(Secret, name: name)

  @doc "Every catalogue entry, by name."
  @spec list() :: [Secret.t()]
  def list, do: Repo.all(from(s in Secret, order_by: s.name))

  @doc """
  Set the value of the secret `name` in OpenBao, and stamp `rotated_at`.

  Options: `vault:` — the `AlexClaw.Vault` server to use.
  """
  @spec put_value(String.t(), String.t(), keyword()) :: :ok | {:error, error()}
  def put_value(name, value, opts \\ []) when is_binary(name) and is_binary(value) do
    result =
      with {:ok, secret} <- fetch(name),
           :ok <- non_empty(value),
           :ok <- well_formed(value),
           :ok <- Vault.write(path(name), %{"value" => value}, server: vault(opts)),
           {:ok, _secret} <- Repo.update(Secret.rotated(secret)) do
        :ok
      end

    AuditLog.log_secret_set(name, outcome(result))
    announce(result, name)
    result
  end

  @doc """
  Delete the secret `name`: its value in OpenBao, with every version and its
  metadata, then its catalogue entry.

  Options: `vault:` — the `AlexClaw.Vault` server to use.
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, error()}
  def delete(name, opts \\ []) when is_binary(name) do
    result =
      with {:ok, secret} <- fetch(name),
           :ok <- Vault.delete(path(name), server: vault(opts)),
           {:ok, _secret} <- Repo.delete(secret) do
        :ok
      end

    AuditLog.log_secret_delete(name, outcome(result))
    announce(result, name)
    result
  end

  @doc """
  The value of the secret `name`, for `destination` — which must be one of the
  secret's bindings, exactly.

  Options: `for:` (required) — the destination; `bindings:` — the bindings to
  check against, for a caller that derives them from a declaration at each use
  (secret settings, `AlexClaw.Config.secret/2`), instead of the catalogue's;
  `vault:` — the `AlexClaw.Vault` server to use.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def resolve(name, opts) when is_binary(name) do
    destination = Keyword.fetch!(opts, :for)

    result =
      with {:ok, secret} <- fetch(name),
           :ok <- bound(Keyword.get(opts, :bindings, secret.binding), destination) do
        read_value(name, vault(opts))
      end

    AuditLog.log_secret_resolve(name, destination, outcome(result))
    remembered(result)
  end

  @doc """
  Whether OpenBao holds exactly `value` for the secret `name` — a read-back
  check for code that has just written it (the upgrade that moves secrets out
  of the database). The value read is compared and dropped, never returned.

  Options: `vault:` — the `AlexClaw.Vault` server to use.
  """
  @spec value_matches?(String.t(), String.t(), keyword()) :: boolean() | {:error, error()}
  def value_matches?(name, value, opts \\ []) when is_binary(name) and is_binary(value) do
    case read_value(name, vault(opts)) do
      {:ok, stored} -> Plug.Crypto.secure_compare(stored, value)
      {:error, reason} -> {:error, reason}
    end
  end

  defp announce(:ok, name),
    do: Phoenix.PubSub.broadcast(AlexClaw.PubSub, @topic, {:secret_rotated, name})

  defp announce(_error, _name), do: :ok

  defp fetch(name) do
    case get(name) do
      nil -> {:error, :unknown_secret}
      secret -> {:ok, secret}
    end
  end

  defp non_empty(""), do: {:error, :empty_value}
  defp non_empty(_value), do: :ok

  # A value with surrounding whitespace or a control character (other than an
  # inner newline or tab: a PEM key, a JSON credential) could only fail where it
  # is sent, and the failure would quote it (S8 H8): it is refused on entry.
  defp well_formed(value) do
    if value == String.trim(value) and not String.match?(value, ~r/[\x00-\x08\x0b-\x1f\x7f]/),
      do: :ok,
      else: {:error, :malformed_value}
  end

  # Every value handed out is remembered for masking (AlexClaw.Secrets.Mask).
  defp remembered({:ok, value} = result) do
    Mask.register(value)
    result
  end

  defp remembered(error), do: error

  defp bound(bindings, destination) do
    if destination in bindings, do: :ok, else: {:error, :not_bound}
  end

  defp read_value(name, vault) do
    case Vault.read(path(name), server: vault) do
      {:ok, %{"value" => value}} when is_binary(value) -> {:ok, value}
      {:ok, _other} -> {:error, :no_value}
      {:error, :not_found} -> {:error, :no_value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp path(name), do: "alexclaw/secrets/" <> name

  defp vault(opts), do: Keyword.get(opts, :vault, Vault)

  # What the audit records: the outcome, never the value.
  defp outcome(:ok), do: :ok
  defp outcome({:ok, _value}), do: :ok
  defp outcome({:error, reason}), do: {:error, reason}
end
