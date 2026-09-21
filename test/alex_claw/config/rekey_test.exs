defmodule AlexClaw.Config.RekeyTest do
  @moduledoc """
  Rotating SECRET_KEY_BASE moves every encrypted setting — the TOTP secret
  among them — to the new key in one audited transaction, ends every login,
  and refuses, with nothing changed, when the old key is wrong.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AdminSession, AuditEntry, Elevation, Sessions}
  alias AlexClaw.Config.{Crypto, Rekey, Setting}

  @old Application.compile_env!(:alex_claw, [AlexClawWeb.Endpoint, :secret_key_base])
  @new String.duplicate("n", 64)

  defp stored(key), do: Repo.get_by!(Setting, key: key).value

  setup do
    {:ok, _} = AlexClaw.Config.set("rekey.api_token", "s3cret-token", sensitive: true)
    {:ok, _} = AlexClaw.Config.set("auth.totp.secret", "JBSWY3DPEHPK3PXP", sensitive: true)
    {:ok, _} = AlexClaw.Config.set("rekey.plain", "not secret")
    :ok
  end

  test "every encrypted setting decrypts under the new key to what it was" do
    assert {:ok, moved} = Rekey.run(@old, @new)
    assert moved >= 2

    for {key, value} <- [
          {"rekey.api_token", "s3cret-token"},
          {"auth.totp.secret", "JBSWY3DPEHPK3PXP"}
        ] do
      assert Crypto.decrypt_with(Crypto.key_for(@new), stored(key)) == {:ok, value}
      assert {:error, _} = Crypto.decrypt_with(Crypto.key_for(@old), stored(key))
    end
  end

  test "a value that was never encrypted is left alone" do
    {:ok, _} = Rekey.run(@old, @new)
    assert stored("rekey.plain") == "not secret"
  end

  test "every login is ended, and the rotation is audited" do
    :ok = Sessions.open(Elevation.new_sid())

    {:ok, moved} = Rekey.run(@old, @new)

    assert Repo.aggregate(AdminSession, :count) == 0

    assert Repo.exists?(
             from(e in AuditEntry,
               where:
                 e.decision == "write" and like(e.reason, ^"SECRET_KEY_BASE rotated: #{moved} %")
             )
           )
  end

  test "the wrong old key changes nothing" do
    before = stored("rekey.api_token")

    assert {:error, message} = Rekey.run(String.duplicate("w", 64), @new)
    assert message =~ "cannot be decrypted with the old SECRET_KEY_BASE"
    assert stored("rekey.api_token") == before
  end

  # After a rotation the old key decrypts nothing, so running it again is
  # refused rather than double-encrypting.
  test "a second run with the same keys is refused" do
    {:ok, _} = Rekey.run(@old, @new)
    after_first = stored("rekey.api_token")

    assert {:error, _} = Rekey.run(@old, @new)
    assert stored("rekey.api_token") == after_first
  end

  test "the same key twice is refused" do
    assert {:error, message} = Rekey.run(@old, @old)
    assert message =~ "the same"
  end
end
