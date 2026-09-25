defmodule AlexClaw.Auth.RecoveryCodes do
  @moduledoc """
  The way back in when the authenticator is gone.

  Ten one-time codes, generated when 2FA is enabled and shown once. What is
  stored is a SHA-256 hash of each: the rows cannot be used to log in, so a
  database dump is not a set of keys. Comparison is constant-time, because a
  timing difference on a fifty-bit secret is a real one.

  A code is consumed by the first redemption that claims it — the update names
  the row only while `used_at` is null, so two tabs racing produce one
  redemption and one refusal rather than two of either.

  These are not an alternative second factor to be kept in a password manager
  beside the password. They are the last resort before reinstalling, and every
  use is audited and announced.
  """

  import Ecto.Query

  alias AlexClaw.Auth.{AuditLog, RecoveryCode}
  alias AlexClaw.Gateway.Router
  alias AlexClaw.Repo

  @count 10
  @group_size 5
  # Crockford base32 without I, L, O and U: a code read off a screen and typed
  # back in should not turn on whether someone wrote a one or an I.
  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @doc "How many codes a fresh set holds."
  @spec count() :: pos_integer()
  def count, do: @count

  @doc """
  Replace the whole set, and return the new codes in the clear.

  This is the only moment the codes exist in readable form: the caller shows
  them once and they are not recoverable afterwards. Generating invalidates
  every earlier code, used or not.
  """
  @spec generate() :: [String.t()]
  def generate do
    Repo.delete_all(RecoveryCode)
    codes = Enum.map(1..@count, fn _n -> new_code() end)

    Repo.insert_all(
      RecoveryCode,
      Enum.map(codes, &%{hash: hash(&1), inserted_at: DateTime.utc_now(:second)})
    )

    AuditLog.log_recovery_codes(:generated, @count)
    codes
  end

  @doc """
  Spend `code` if it is one of the unused ones.

  Returns how many remain, which is what the operator needs to know next.
  """
  @spec redeem(String.t()) :: {:ok, non_neg_integer()} | {:error, :invalid_code}
  def redeem(code) do
    code
    |> normalize()
    |> claim()
  end

  @doc "Whether `code` is one of the unused codes, without spending it."
  @spec valid?(String.t()) :: boolean()
  def valid?(code) do
    candidate = normalize(code)

    candidate
    |> hash()
    |> matching_row()
    |> unspent?(candidate)
  end

  defp unspent?(nil, _candidate), do: false

  defp unspent?(%RecoveryCode{} = row, candidate),
    do: Plug.Crypto.secure_compare(row.hash, hash(candidate))

  @doc "How many codes are left to use."
  @spec remaining() :: non_neg_integer()
  def remaining do
    Repo.aggregate(from(c in RecoveryCode, where: is_nil(c.used_at)), :count)
  end

  @doc "Whether any codes exist at all — a set that was never generated is not a set."
  @spec generated?() :: boolean()
  def generated?, do: Repo.aggregate(RecoveryCode, :count) > 0

  @doc "When a code was last spent, or nil."
  @spec last_used_at() :: DateTime.t() | nil
  def last_used_at do
    Repo.one(from(c in RecoveryCode, where: not is_nil(c.used_at), select: max(c.used_at)))
  end

  @doc """
  What a page needs to know about the codes without asking three questions.

  `generated?` is false on an instance where 2FA was enabled from a gateway and
  nobody has been to the admin UI yet — that is the state the banner exists for.
  """
  @spec status() :: %{
          generated?: boolean(),
          remaining: non_neg_integer(),
          last_used_at: DateTime.t() | nil
        }
  def status do
    %{generated?: generated?(), remaining: remaining(), last_used_at: last_used_at()}
  end

  @doc "Forget every code. Used when 2FA is turned off — they unlock nothing now."
  @spec discard() :: :ok
  def discard do
    Repo.delete_all(RecoveryCode)
    :ok
  end

  # --- Internals ---

  # The lookup is by hash, so the query itself does not leak which code was
  # tried; secure_compare guards the comparison that decides.
  defp claim(candidate) do
    candidate
    |> hash()
    |> matching_row()
    |> spend(candidate)
  end

  defp matching_row(hash) do
    Repo.one(from(c in RecoveryCode, where: c.hash == ^hash and is_nil(c.used_at)))
  end

  defp spend(nil, _candidate), do: {:error, :invalid_code}

  defp spend(%RecoveryCode{} = row, candidate) do
    verified(Plug.Crypto.secure_compare(row.hash, hash(candidate)), row)
  end

  defp verified(false, _row), do: {:error, :invalid_code}

  defp verified(true, row) do
    row
    |> mark_used()
    |> report()
  end

  # Only the row that is still unused is claimed, so a second redemption of the
  # same code updates nothing and is refused.
  defp mark_used(%RecoveryCode{id: id}) do
    from(c in RecoveryCode, where: c.id == ^id and is_nil(c.used_at))
    |> Repo.update_all(set: [used_at: DateTime.utc_now(:second)])
  end

  defp report({0, _rows}), do: {:error, :invalid_code}

  defp report({1, _rows}) do
    left = remaining()
    AuditLog.log_recovery_code_used(left)
    announce(left, Router.active_gateways())
    {:ok, left}
  end

  defp announce(_left, []), do: :ok

  defp announce(left, _gateways) do
    Router.broadcast(
      "⚠️ A recovery code was used to authenticate in the admin UI. #{left} remaining."
    )

    :ok
  end

  defp new_code do
    [group(), group()] |> Enum.join("-")
  end

  defp group do
    1..@group_size
    |> Enum.map(fn _n -> Enum.random(@alphabet) end)
    |> to_string()
  end

  defp hash(code) do
    :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower)
  end

  # Typed back in, a code arrives with whatever case and spacing the operator
  # used. The hyphen is punctuation, not part of the secret.
  defp normalize(code) do
    code
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^0-9A-Z]/, "")
    |> group_with_hyphen()
  end

  defp group_with_hyphen(<<first::binary-size(@group_size), rest::binary>>),
    do: first <> "-" <> rest

  defp group_with_hyphen(other), do: other
end
