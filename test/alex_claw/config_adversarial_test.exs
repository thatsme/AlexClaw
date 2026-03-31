defmodule AlexClaw.ConfigAdversarialTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :adversarial

  alias AlexClaw.Config

  describe "set/3 edge cases" do
    test "rejects very long key (DB varchar limit)" do
      long_key = String.duplicate("k", 500)
      assert_raise Postgrex.Error, fn ->
        Config.set(long_key, "value")
      end
    end

    test "handles very long value" do
      long_value = String.duplicate("v", 100_000)
      {:ok, _} = Config.set("long_value_key", long_value)
      assert Config.get("long_value_key") == long_value
    end

    test "handles unicode keys and values" do
      {:ok, _} = Config.set("emoji.key.🚀", "value 日本語")
      assert Config.get("emoji.key.🚀") == "value 日本語"
    end

    test "accepts empty string value" do
      {:ok, setting} = Config.set("empty_val", "")
      assert setting.value == ""
      assert Config.get("empty_val") == ""
    end

    test "handles value with special chars" do
      {:ok, _} = Config.set("special_chars", "line1\nline2\ttab\r\n\"quoted\"")
      assert Config.get("special_chars") =~ "line1\nline2"
    end

    test "upserts — second set overwrites first" do
      {:ok, _} = Config.set("upsert_key", "first")
      {:ok, _} = Config.set("upsert_key", "second")
      assert Config.get("upsert_key") == "second"
    end

    test "boolean casting — 'true' and 'false'" do
      {:ok, _} = Config.set("bool_t", "true", type: "boolean")
      {:ok, _} = Config.set("bool_f", "false", type: "boolean")
      assert Config.get("bool_t") == true
      assert Config.get("bool_f") == false
    end

    test "boolean casting — non-'true' is false" do
      {:ok, _} = Config.set("bool_x", "yes", type: "boolean")
      assert Config.get("bool_x") == false
    end

    test "integer casting" do
      {:ok, _} = Config.set("int_key", "42", type: "integer")
      assert Config.get("int_key") == 42
    end

    test "float casting" do
      {:ok, _} = Config.set("float_key", "3.14", type: "float")
      assert Config.get("float_key") == 3.14
    end

    test "json casting with nested structure" do
      value = %{"nested" => %{"deep" => [1, 2, 3]}}
      {:ok, _} = Config.set("json_key", value, type: "json")
      assert Config.get("json_key") == value
    end

    test "json casting with list" do
      value = [1, "two", %{"three" => 3}]
      {:ok, _} = Config.set("json_list", value, type: "json")
      assert Config.get("json_list") == value
    end
  end

  describe "get/2 edge cases" do
    test "returns default for missing key" do
      assert Config.get("nonexistent_key_#{System.unique_integer()}", :fallback) == :fallback
    end

    test "returns nil by default for missing key" do
      assert Config.get("missing_#{System.unique_integer()}") == nil
    end
  end

  describe "delete/1 edge cases" do
    test "delete nonexistent key is idempotent" do
      assert :ok = Config.delete("never_existed_#{System.unique_integer()}")
    end

    test "delete removes from both DB and ETS" do
      {:ok, _} = Config.set("del_test", "present")
      assert Config.get("del_test") == "present"
      Config.delete("del_test")
      assert Config.get("del_test") == nil
    end

    test "double delete is safe" do
      {:ok, _} = Config.set("double_del", "value")
      Config.delete("double_del")
      assert :ok = Config.delete("double_del")
    end
  end
end
