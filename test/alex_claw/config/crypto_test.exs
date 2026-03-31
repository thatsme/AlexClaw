defmodule AlexClaw.Config.CryptoTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Config.Crypto

  describe "encrypt/1 and decrypt/1" do
    test "round-trips a plaintext string" do
      {:ok, encrypted} = Crypto.encrypt("my-secret-key-123")
      assert String.starts_with?(encrypted, "enc:")
      {:ok, decrypted} = Crypto.decrypt(encrypted)
      assert decrypted == "my-secret-key-123"
    end

    test "produces different ciphertext each time (random IV)" do
      {:ok, a} = Crypto.encrypt("same-input")
      {:ok, b} = Crypto.encrypt("same-input")
      assert a != b
    end

    test "empty string is never encrypted" do
      {:ok, result} = Crypto.encrypt("")
      assert result == ""
    end

    test "handles unicode" do
      {:ok, encrypted} = Crypto.encrypt("日本語テスト🚀")
      {:ok, decrypted} = Crypto.decrypt(encrypted)
      assert decrypted == "日本語テスト🚀"
    end

    test "handles long values" do
      long = String.duplicate("x", 100_000)
      {:ok, encrypted} = Crypto.encrypt(long)
      {:ok, decrypted} = Crypto.decrypt(encrypted)
      assert decrypted == long
    end
  end

  describe "decrypt/1 passthrough" do
    test "returns plaintext for non-enc: values" do
      {:ok, result} = Crypto.decrypt("just-a-plain-value")
      assert result == "just-a-plain-value"
    end

    test "returns nil for nil" do
      {:ok, result} = Crypto.decrypt(nil)
      assert result == nil
    end
  end

  describe "decrypt/1 error cases" do
    test "returns error for tampered ciphertext" do
      {:ok, "enc:" <> payload} = Crypto.encrypt("secret")
      # Decode, flip bytes in the ciphertext portion, re-encode
      raw = Base.decode64!(payload)
      flipped = :binary.bin_to_list(raw) |> Enum.map(&Bitwise.bxor(&1, 0xFF)) |> :binary.list_to_bin()
      tampered = "enc:" <> Base.encode64(flipped)
      assert {:error, _} = Crypto.decrypt(tampered)
    end

    test "returns error for invalid base64 after enc: prefix" do
      assert {:error, :invalid_base64} = Crypto.decrypt("enc:not-valid-base64!!!")
    end

    test "returns error for too-short ciphertext" do
      short = Base.encode64("tooshort")
      assert {:error, :invalid_ciphertext} = Crypto.decrypt("enc:" <> short)
    end
  end

  describe "encrypted?/1" do
    test "true for enc: prefixed strings" do
      assert Crypto.encrypted?("enc:abc123")
    end

    test "false for plain strings" do
      refute Crypto.encrypted?("plain-value")
    end

    test "false for nil" do
      refute Crypto.encrypted?(nil)
    end
  end

  describe "encrypt!/1" do
    test "returns encrypted string" do
      result = Crypto.encrypt!("test")
      assert String.starts_with?(result, "enc:")
    end
  end
end
