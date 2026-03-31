defmodule AlexClaw.Config.EncryptExistingTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config
  alias AlexClaw.Config.{Crypto, EncryptExisting, Setting}
  alias AlexClaw.Repo

  describe "run/0" do
    test "encrypts plaintext sensitive settings" do
      {:ok, _} = Config.set("test.secret", "my-api-key", sensitive: true)

      # Manually reset the DB value to plaintext (simulating pre-encryption state)
      setting = Repo.get_by!(Setting, key: "test.secret")
      setting |> Ecto.Changeset.change(%{value: "my-api-key"}) |> Repo.update!()

      :ok = EncryptExisting.run()

      updated = Repo.get_by!(Setting, key: "test.secret")
      assert Crypto.encrypted?(updated.value)
      {:ok, decrypted} = Crypto.decrypt(updated.value)
      assert decrypted == "my-api-key"
    end

    test "skips already-encrypted values (idempotent)" do
      {:ok, _} = Config.set("test.already_enc", "secret-value", sensitive: true)

      setting = Repo.get_by!(Setting, key: "test.already_enc")
      original_value = setting.value
      assert Crypto.encrypted?(original_value)

      :ok = EncryptExisting.run()

      updated = Repo.get_by!(Setting, key: "test.already_enc")
      # Value should not be double-encrypted
      assert updated.value == original_value
    end

    test "skips empty values" do
      {:ok, _} = Config.set("test.empty_sensitive", "", sensitive: true)

      :ok = EncryptExisting.run()

      updated = Repo.get_by!(Setting, key: "test.empty_sensitive")
      assert updated.value == ""
    end

    test "skips non-sensitive settings" do
      {:ok, _} = Config.set("test.not_sensitive", "plain-value", sensitive: false)

      :ok = EncryptExisting.run()

      updated = Repo.get_by!(Setting, key: "test.not_sensitive")
      refute Crypto.encrypted?(updated.value)
      assert updated.value == "plain-value"
    end
  end
end
