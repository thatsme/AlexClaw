defmodule AlexClaw.Auth.AdminPassword do
  @moduledoc """
  The admin password, kept as a salted, slow hash — never as the password.

  The hash is PBKDF2-HMAC-SHA256 with 600,000 iterations and a 16-byte random
  salt, from OTP's own `:crypto`, stored in the `auth.admin_password_hash` row
  as `$pbkdf2-sha256$<iterations>$<salt>$<key>` (base64). It is local rather
  than in OpenBao: logging in has to work while OpenBao is sealed, which is
  when the operator needs the admin UI.

  `ADMIN_PASSWORD` is where the first password comes from. The first
  successful login stores its hash; from then on the variable is ignored, and
  changing it does not change the password.
  """

  alias AlexClaw.Config.Setting
  alias AlexClaw.Repo

  @key "auth.admin_password_hash"
  @iterations 600_000
  @salt_bytes 16
  @key_bytes 32

  @doc "The number of PBKDF2 iterations a new hash uses."
  @spec iterations() :: pos_integer()
  def iterations, do: @iterations

  @doc "A new salted hash of `password`."
  @spec hash(String.t()) :: String.t()
  def hash(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    encode(@iterations, salt, derive(password, salt, @iterations))
  end

  @doc "Whether `password` is the one `hash` was made from. Constant time."
  @spec verify(String.t(), String.t()) :: boolean()
  def verify(password, hash) when is_binary(password) and is_binary(hash),
    do: password |> decoded(decode(hash)) |> matched()

  defp decoded(password, {:ok, iterations, salt, key}),
    do: {derive(password, salt, iterations), key}

  defp decoded(_password, :error), do: :error

  defp matched({derived, key}), do: Plug.Crypto.secure_compare(derived, key)
  defp matched(:error), do: false

  @doc """
  Check a login's `password`. Against the stored hash when there is one;
  otherwise against `ADMIN_PASSWORD`, and on a match its hash is stored —
  from then on the variable is ignored.
  """
  @spec authenticate(String.t()) :: :ok | {:error, :invalid_password | :no_admin_password}
  def authenticate(password) when is_binary(password),
    do: authenticated(stored(), configured(), password)

  defp authenticated(nil, nil, _password), do: {:error, :no_admin_password}

  defp authenticated(nil, configured, password) do
    with :ok <- equal(Plug.Crypto.secure_compare(password, configured)) do
      store(hash(password))
    end
  end

  defp authenticated(hash, _configured, password), do: equal(verify(password, hash))

  defp equal(true), do: :ok
  defp equal(false), do: {:error, :invalid_password}

  defp configured do
    case Application.get_env(:alex_claw, :admin_password) do
      password when is_binary(password) and password != "" -> password
      _unset -> nil
    end
  end

  @doc "The stored hash, or nil before the first login."
  @spec stored() :: String.t() | nil
  def stored do
    case Repo.get_by(Setting, key: @key) do
      %Setting{value: "$pbkdf2-sha256$" <> _ = hash} -> hash
      _none -> nil
    end
  end

  @doc "Store `hash` as the admin password's."
  @spec store(String.t()) :: :ok
  def store("$pbkdf2-sha256$" <> _ = hash) do
    {:ok, _setting} =
      (Repo.get_by(Setting, key: @key) || %Setting{key: @key})
      |> Setting.changeset(%{
        key: @key,
        value: hash,
        type: "string",
        category: "auth",
        description: "Admin password hash (PBKDF2-HMAC-SHA256)",
        sensitive: true
      })
      |> Repo.insert_or_update()

    :ok
  end

  @doc """
  What identifies the current password without revealing it: the stored hash
  when there is one, else `ADMIN_PASSWORD`. A login is made under it and ends
  when it changes (`AlexClaw.Auth.Sessions`).
  """
  @spec current() :: String.t()
  def current, do: stored() || "env:" <> (configured() || "")

  defp derive(password, salt, iterations),
    do: :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, @key_bytes)

  defp encode(iterations, salt, key),
    do: "$pbkdf2-sha256$#{iterations}$#{Base.encode64(salt)}$#{Base.encode64(key)}"

  defp decode("$pbkdf2-sha256$" <> rest) do
    with [iterations, salt, key] <- String.split(rest, "$"),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.decode64(salt),
         {:ok, key} <- Base.decode64(key) do
      {:ok, iterations, salt, key}
    else
      _malformed -> :error
    end
  end

  defp decode(_other), do: :error
end
