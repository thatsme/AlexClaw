defmodule AlexClaw.Auth.CapabilityToken do
  @moduledoc """
  HMAC-signed capability tokens with Macaroon-style attenuation.

  A token carries a set of permissions that can only be further
  restricted (attenuated), never expanded. Each attenuation re-signs
  the token, creating a verifiable chain.

  Tokens are ephemeral (workflow-scoped) and never stored.
  Signing key is derived from SECRET_KEY_BASE via HKDF.
  """

  @enforce_keys [:permissions, :caveats, :signature]
  defstruct [:permissions, :caveats, :signature]

  @type caveat :: {:max_depth, non_neg_integer()} | {:expires_at, DateTime.t()}

  @type t :: %__MODULE__{
          permissions: MapSet.t(atom()),
          caveats: [caveat()],
          signature: binary()
        }

  @doc "Create a new token with the given permissions."
  @spec mint([atom()], keyword()) :: t()
  def mint(permissions, opts \\ []) do
    caveats = build_caveats(opts)
    perms = MapSet.new(permissions)

    %__MODULE__{
      permissions: perms,
      caveats: caveats,
      signature: sign(perms, caveats)
    }
  end

  @doc """
  Attenuate a token — restrict permissions to the intersection
  of the current set and the given subset. Optionally add caveats.

  Returns `{:ok, attenuated_token}` or `{:error, :invalid_token}`.
  """
  @spec attenuate(t(), [atom()], keyword()) :: {:ok, t()} | {:error, :invalid_token}
  def attenuate(%__MODULE__{} = token, restricted_permissions, opts \\ []) do
    case verify(token) do
      {:ok, _perms} ->
        new_perms = MapSet.intersection(token.permissions, MapSet.new(restricted_permissions))
        new_caveats = token.caveats ++ build_caveats(opts)

        {:ok,
         %__MODULE__{
           permissions: new_perms,
           caveats: new_caveats,
           signature: sign(new_perms, new_caveats)
         }}

      error ->
        error
    end
  end

  @doc """
  Verify token integrity and check caveats.

  Returns `{:ok, permissions}` or `{:error, reason}`.
  """
  @spec verify(t()) :: {:ok, MapSet.t(atom())} | {:error, atom()}
  def verify(%__MODULE__{} = token) do
    expected = sign(token.permissions, token.caveats)

    if Plug.Crypto.secure_compare(token.signature, expected) do
      check_caveats(token)
    else
      {:error, :invalid_token}
    end
  end

  @doc "Check if a verified token grants the given permission."
  @spec has_permission?(t(), atom()) :: boolean()
  def has_permission?(%__MODULE__{} = token, permission) do
    case verify(token) do
      {:ok, perms} -> MapSet.member?(perms, permission)
      {:error, _} -> false
    end
  end

  # --- Internals ---

  defp build_caveats(opts) do
    caveats = []
    caveats = if opts[:max_depth], do: [{:max_depth, opts[:max_depth]} | caveats], else: caveats
    caveats = if opts[:expires_at], do: [{:expires_at, opts[:expires_at]} | caveats], else: caveats
    caveats
  end

  defp check_caveats(%__MODULE__{permissions: perms, caveats: caveats}) do
    Enum.reduce_while(caveats, {:ok, perms}, fn
      {:expires_at, expires_at}, acc ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          {:cont, acc}
        else
          {:halt, {:error, :token_expired}}
        end

      {:max_depth, max_depth}, acc ->
        depth = Process.get(:auth_chain_depth, 0)

        if depth <= max_depth do
          {:cont, acc}
        else
          {:halt, {:error, :max_depth_exceeded}}
        end

      _unknown_caveat, acc ->
        {:cont, acc}
    end)
  end

  defp sign(permissions, caveats) do
    payload =
      :erlang.term_to_binary({Enum.sort(MapSet.to_list(permissions)), caveats})

    Base.encode64(:crypto.mac(:hmac, :sha256, signing_key(), payload))
  end

  defp signing_key do
    case :persistent_term.get({__MODULE__, :key}, nil) do
      nil ->
        secret = fetch_secret_key_base!()
        key = hkdf_sha256(secret, "AlexClaw.Auth.CapabilityToken", 32)
        :persistent_term.put({__MODULE__, :key}, key)
        key

      key ->
        key
    end
  end

  defp fetch_secret_key_base! do
    case Application.get_env(:alex_claw, AlexClawWeb.Endpoint)[:secret_key_base] do
      nil -> raise "SECRET_KEY_BASE not configured"
      secret when byte_size(secret) < 32 -> raise "SECRET_KEY_BASE too short"
      secret -> secret
    end
  end

  defp hkdf_sha256(ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, ikm)

    binary_part(:crypto.mac(:hmac, :sha256, prk, <<info::binary, 1>>), 0, length)
  end
end
