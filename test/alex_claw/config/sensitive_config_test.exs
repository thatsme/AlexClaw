defmodule AlexClaw.Config.SensitiveConfigTest do
  @moduledoc """
  Since 0.4.0 (S7) `sensitive` marks a setting kept from skills and from the
  admin UI's plain view; it no longer means encrypted. No credential is stored
  in the settings table: a declared secret setting is in OpenBao, and a key
  named like a credential is refused (`credential_keys_test.exs`).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config
  alias AlexClaw.Config.Setting
  alias AlexClaw.Repo

  describe "set/3 with sensitive: true" do
    test "stores the value as given, flagged sensitive" do
      {:ok, setting} = Config.set("test.private", "p-12345", sensitive: true)

      assert setting.value == "p-12345"
      assert Config.get("test.private") == "p-12345"
      assert Config.sensitive?("test.private")
    end

    test "does not encrypt empty values" do
      {:ok, setting} = Config.set("test.empty_key", "", sensitive: true)
      assert setting.value == ""
    end

    test "preserves sensitive flag on update without explicit opt" do
      {:ok, _} = Config.set("test.preserve", "v1", sensitive: true)
      {:ok, setting} = Config.set("test.preserve", "v2")

      assert setting.sensitive == true
      assert setting.value == "v2"
      assert Config.get("test.preserve") == "v2"
    end

    test "non-sensitive values are stored as plaintext" do
      {:ok, setting} = Config.set("test.plain", "visible", sensitive: false)
      assert setting.value == "visible"
      refute setting.sensitive
    end
  end

  describe "list/1" do
    test "list returns sensitive settings with their flag" do
      {:ok, _} =
        Config.set("test.list_private", "listed-value", sensitive: true, category: "test_cat")

      settings = Config.list("test_cat")
      setting = Enum.find(settings, &(&1.key == "test.list_private"))

      assert setting.value == "listed-value"
      assert setting.sensitive == true
    end
  end

  describe "init/0 reload" do
    test "ETS holds the value after reload" do
      {:ok, _} = Config.set("test.reload", "reload-value", sensitive: true)

      db_setting = Repo.get_by!(Setting, key: "test.reload")
      assert db_setting.value == "reload-value"

      # Reload ETS from DB
      Config.init()

      assert Config.get("test.reload") == "reload-value"
    end
  end

  describe "setting schema" do
    test "sensitive field defaults to false" do
      {:ok, setting} = Config.set("test.default_sens", "val")
      assert setting.sensitive == false
    end
  end
end
