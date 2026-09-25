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
  alias AlexClaw.Secrets.Secret
  alias AlexClaw.Vault

  @type error :: :unknown_secret | :not_bound | :no_value | :empty_value | Vault.error()

  @doc "Define a secret: name, description, kind, binding. Never a value."
  @spec define(map()) :: {:ok, Secret.t()} | {:error, Ecto.Changeset.t()}
  def define(attrs) do
    %Secret{}
    |> Secret.changeset(attrs)
    |> Repo.insert()
  end

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
           :ok <- Vault.write(path(name), %{"value" => value}, server: vault(opts)),
           {:ok, _secret} <- Repo.update(Secret.rotated(secret)) do
        :ok
      end

    AuditLog.log_secret_set(name, outcome(result))
    result
  end

  @doc """
  The value of the secret `name`, for `destination` — which must be one of the
  secret's bindings, exactly.

  Options: `for:` (required) — the destination; `vault:` — the `AlexClaw.Vault`
  server to use.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def resolve(name, opts) when is_binary(name) do
    destination = Keyword.fetch!(opts, :for)

    result =
      with {:ok, secret} <- fetch(name),
           :ok <- bound(secret, destination) do
        read_value(name, vault(opts))
      end

    AuditLog.log_secret_resolve(name, destination, outcome(result))
    result
  end

  defp fetch(name) do
    case get(name) do
      nil -> {:error, :unknown_secret}
      secret -> {:ok, secret}
    end
  end

  defp non_empty(""), do: {:error, :empty_value}
  defp non_empty(_value), do: :ok

  defp bound(%Secret{binding: binding}, destination) do
    if destination in binding, do: :ok, else: {:error, :not_bound}
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
