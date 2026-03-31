defmodule AlexClaw.Config.SensitiveConfigTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config
  alias AlexClaw.Config.{Crypto, Setting}
  alias AlexClaw.Repo

  describe "set/3 with sensitive: true" do
    test "encrypts value in DB, stores plaintext in ETS" do
      {:ok, setting} = Config.set("test.api_key", "sk-12345", sensitive: true)

      # DB value is encrypted
      assert Crypto.encrypted?(setting.value)

      # ETS has plaintext
      assert Config.get("test.api_key") == "sk-12345"
    end

    test "does not encrypt empty values" do
      {:ok, setting} = Config.set("test.empty_key", "", sensitive: true)
      assert setting.value == ""
    end

    test "preserves sensitive flag on update without explicit opt" do
      {:ok, _} = Config.set("test.preserve", "v1", sensitive: true)
      {:ok, setting} = Config.set("test.preserve", "v2")

      assert setting.sensitive == true
      assert Crypto.encrypted?(setting.value)
      assert Config.get("test.preserve") == "v2"
    end

    test "non-sensitive values are stored as plaintext" do
      {:ok, setting} = Config.set("test.plain", "visible", sensitive: false)
      refute Crypto.encrypted?(setting.value)
      assert setting.value == "visible"
    end
  end

  describe "list/1 decryption" do
    test "list returns decrypted values for sensitive settings" do
      {:ok, _} = Config.set("test.list_secret", "decrypted-value", sensitive: true, category: "test_cat")

      settings = Config.list("test_cat")
      setting = Enum.find(settings, &(&1.key == "test.list_secret"))

      assert setting.value == "decrypted-value"
      assert setting.sensitive == true
    end
  end

  describe "init/0 reload" do
    test "ETS contains decrypted values after reload" do
      {:ok, _} = Config.set("test.reload", "reload-secret", sensitive: true)

      # Verify DB has encrypted value
      db_setting = Repo.get_by!(Setting, key: "test.reload")
      assert Crypto.encrypted?(db_setting.value)

      # Reload ETS from DB
      Config.init()

      # ETS should have plaintext
      assert Config.get("test.reload") == "reload-secret"
    end
  end

  describe "setting schema" do
    test "sensitive field defaults to false" do
      {:ok, setting} = Config.set("test.default_sens", "val")
      assert setting.sensitive == false
    end
  end
end
