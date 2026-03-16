defmodule AlexClaw.ConfigTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Config

  describe "get/2" do
    test "returns default when key not set" do
      assert Config.get("nonexistent.key") == nil
      assert Config.get("nonexistent.key", "fallback") == "fallback"
    end

    test "returns value from ETS" do
      :ets.insert(:alexclaw_config, {"test.direct", "direct_value"})
      assert Config.get("test.direct") == "direct_value"
    end
  end

  describe "set/3" do
    test "persists string value to DB and ETS" do
      {:ok, setting} = Config.set("test.str", "hello")
      assert setting.key == "test.str"
      assert setting.value == "hello"
      assert setting.type == "string"
      assert Config.get("test.str") == "hello"
    end

    test "persists integer value with correct type" do
      {:ok, _} = Config.set("test.int", 42, type: "integer")
      assert Config.get("test.int") == 42
    end

    test "persists float value with correct type" do
      {:ok, _} = Config.set("test.float", "3.14", type: "float")
      assert Config.get("test.float") == 3.14
    end

    test "persists boolean value" do
      {:ok, _} = Config.set("test.bool_t", "true", type: "boolean")
      {:ok, _} = Config.set("test.bool_f", "false", type: "boolean")
      assert Config.get("test.bool_t") == true
      assert Config.get("test.bool_f") == false
    end

    test "persists json value" do
      {:ok, _} = Config.set("test.json", %{"a" => 1}, type: "json")
      assert Config.get("test.json") == %{"a" => 1}
    end

    test "updates existing key" do
      {:ok, _} = Config.set("test.upd", "first")
      assert Config.get("test.upd") == "first"

      {:ok, _} = Config.set("test.upd", "second")
      assert Config.get("test.upd") == "second"
    end

    test "stores category" do
      {:ok, setting} = Config.set("test.cat", "v", category: "telegram")
      assert setting.category == "telegram"
    end
  end

  describe "delete/1" do
    test "removes from DB and ETS" do
      {:ok, _} = Config.set("test.del", "gone")
      assert Config.get("test.del") == "gone"

      :ok = Config.delete("test.del")
      assert Config.get("test.del") == nil
    end

    test "no error when deleting nonexistent key" do
      assert :ok = Config.delete("does.not.exist")
    end
  end

  describe "list/1" do
    test "lists all settings" do
      {:ok, _} = Config.set("list.a", "1")
      {:ok, _} = Config.set("list.b", "2")

      settings = Config.list()
      keys = Enum.map(settings, & &1.key)
      assert "list.a" in keys
      assert "list.b" in keys
    end

    test "filters by category" do
      {:ok, _} = Config.set("cat.x", "v", category: "special")
      {:ok, _} = Config.set("cat.y", "v", category: "general")

      special = Config.list("special")
      assert Enum.all?(special, &(&1.category == "special"))
    end
  end
end
