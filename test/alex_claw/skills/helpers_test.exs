defmodule AlexClaw.Skills.HelpersTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Skills.Helpers

  describe "blank?/1" do
    test "nil is blank" do
      assert Helpers.blank?(nil)
    end

    test "empty string is blank" do
      assert Helpers.blank?("")
    end

    test "non-empty string is not blank" do
      refute Helpers.blank?("hello")
    end

    test "zero is not blank" do
      refute Helpers.blank?(0)
    end

    test "false is not blank" do
      refute Helpers.blank?(false)
    end
  end

  describe "parse_int/2" do
    test "parses valid integer string" do
      assert Helpers.parse_int("42", 0) == 42
    end

    test "returns default for nil" do
      assert Helpers.parse_int(nil, 99) == 99
    end

    test "passes through integer value" do
      assert Helpers.parse_int(42, 0) == 42
    end

    test "returns default for invalid string" do
      assert Helpers.parse_int("abc", 0) == 0
    end

    test "returns default for non-string non-integer" do
      assert Helpers.parse_int(:atom, 0) == 0
    end

    test "parses string with trailing chars" do
      assert Helpers.parse_int("42px", 0) == 42
    end
  end

  describe "parse_float/2" do
    test "parses valid float string" do
      assert Helpers.parse_float("3.14", 0.0) == 3.14
    end

    test "returns default for nil" do
      assert Helpers.parse_float(nil, 1.0) == 1.0
    end

    test "passes through float value" do
      assert Helpers.parse_float(3.14, 0.0) == 3.14
    end

    test "converts integer to float" do
      assert Helpers.parse_float(42, 0.0) == 42.0
    end

    test "returns default for invalid string" do
      assert Helpers.parse_float("abc", 0.0) == 0.0
    end

    test "returns default for non-string non-number" do
      assert Helpers.parse_float(:atom, 0.0) == 0.0
    end
  end

  describe "sanitize_utf8/1" do
    test "passes through valid UTF-8" do
      assert Helpers.sanitize_utf8("hello world") == "hello world"
    end

    test "passes through unicode" do
      assert Helpers.sanitize_utf8("Ciao! Привет 日本語") == "Ciao! Привет 日本語"
    end

    test "strips invalid bytes" do
      invalid = "hello" <> <<0xFF>> <> "world"
      result = Helpers.sanitize_utf8(invalid)
      assert is_binary(result)
      assert String.valid?(result)
    end
  end

  describe "strip_noise/1" do
    test "removes script tags" do
      {:ok, doc} = Floki.parse_document("<html><body><p>text</p><script>evil()</script></body></html>")
      result = Helpers.strip_noise(doc)
      assert Floki.find(result, "script") == []
      assert Floki.text(result) =~ "text"
    end

    test "removes style tags" do
      {:ok, doc} = Floki.parse_document("<html><body><p>text</p><style>.x{}</style></body></html>")
      result = Helpers.strip_noise(doc)
      assert Floki.find(result, "style") == []
    end

    test "preserves content outside noise elements" do
      {:ok, doc} = Floki.parse_document("<html><body><p>keep this</p><nav>remove</nav></body></html>")
      result = Helpers.strip_noise(doc)
      text = Floki.text(result)
      assert text =~ "keep this"
      refute text =~ "remove"
    end
  end
end
