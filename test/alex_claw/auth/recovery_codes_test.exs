defmodule AlexClaw.Auth.RecoveryCodesTest do
  @moduledoc """
  The last resort before reinstalling.

  What is stored must not be usable to log in, a code must work exactly once,
  and a fresh set must make the old one worthless. Those three are the whole
  contract, and each is tested by trying to break it.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{RecoveryCode, RecoveryCodes}

  setup do
    RecoveryCodes.discard()
    on_exit(&RecoveryCodes.discard/0)
    :ok
  end

  describe "generate/0" do
    test "returns ten codes" do
      codes = RecoveryCodes.generate()

      assert length(codes) == RecoveryCodes.count()
      assert length(Enum.uniq(codes)) == RecoveryCodes.count()
    end

    test "codes are grouped for reading off a screen" do
      for code <- RecoveryCodes.generate() do
        assert code =~ ~r/^[0-9A-Z]{5}-[0-9A-Z]{5}$/
      end
    end

    # I, L, O and U are left out: a code typed back in should not turn on
    # whether someone read a one or an I.
    test "codes avoid the letters that look like digits" do
      for code <- RecoveryCodes.generate() do
        refute code =~ ~r/[ILOU]/
      end
    end

    test "replaces any earlier set" do
      old = RecoveryCodes.generate()
      RecoveryCodes.generate()

      assert {:error, :invalid_code} = RecoveryCodes.redeem(hd(old))
      assert RecoveryCodes.remaining() == RecoveryCodes.count()
    end

    test "counts as generated" do
      refute RecoveryCodes.generated?()

      RecoveryCodes.generate()

      assert RecoveryCodes.generated?()
    end
  end

  describe "what is stored" do
    # A database dump must not be a set of keys.
    test "is not the code" do
      [code | _rest] = RecoveryCodes.generate()
      stored = Repo.all(RecoveryCode)

      for row <- stored do
        refute row.hash == code
        refute String.contains?(row.hash, String.replace(code, "-", ""))
      end
    end

    test "is a sha-256 hash, and nothing else about the code" do
      RecoveryCodes.generate()

      for row <- Repo.all(RecoveryCode) do
        assert row.hash =~ ~r/^[0-9a-f]{64}$/
        assert row.used_at == nil
      end
    end
  end

  describe "redeem/1" do
    test "spends a code and says how many are left" do
      [code | _rest] = RecoveryCodes.generate()

      assert {:ok, remaining} = RecoveryCodes.redeem(code)
      assert remaining == RecoveryCodes.count() - 1
    end

    test "refuses the same code a second time" do
      [code | _rest] = RecoveryCodes.generate()
      {:ok, _remaining} = RecoveryCodes.redeem(code)

      assert {:error, :invalid_code} = RecoveryCodes.redeem(code)
      assert RecoveryCodes.remaining() == RecoveryCodes.count() - 1
    end

    test "refuses a code that was never issued" do
      RecoveryCodes.generate()

      assert {:error, :invalid_code} = RecoveryCodes.redeem("ZZZZZ-ZZZZZ")
    end

    test "refuses anything when no codes exist" do
      assert {:error, :invalid_code} = RecoveryCodes.redeem("ZZZZZ-ZZZZZ")
    end

    test "refuses an empty string rather than matching something" do
      RecoveryCodes.generate()

      assert {:error, :invalid_code} = RecoveryCodes.redeem("")
    end

    # Typed back in, a code arrives however the operator typed it.
    test "accepts a code in lower case" do
      [code | _rest] = RecoveryCodes.generate()

      assert {:ok, _remaining} = RecoveryCodes.redeem(String.downcase(code))
    end

    test "accepts a code without its hyphen" do
      [code | _rest] = RecoveryCodes.generate()

      assert {:ok, _remaining} = RecoveryCodes.redeem(String.replace(code, "-", ""))
    end

    test "accepts a code with spaces around it" do
      [code | _rest] = RecoveryCodes.generate()

      assert {:ok, _remaining} = RecoveryCodes.redeem("  #{code} ")
    end

    test "each code is independent" do
      [first, second | _rest] = RecoveryCodes.generate()
      {:ok, _remaining} = RecoveryCodes.redeem(first)

      assert {:ok, remaining} = RecoveryCodes.redeem(second)
      assert remaining == RecoveryCodes.count() - 2
    end

    test "records when it was used" do
      [code | _rest] = RecoveryCodes.generate()

      assert RecoveryCodes.last_used_at() == nil
      {:ok, _remaining} = RecoveryCodes.redeem(code)

      assert %DateTime{} = RecoveryCodes.last_used_at()
    end
  end

  describe "status/0" do
    test "reports nothing generated on a fresh instance" do
      assert RecoveryCodes.status() == %{generated?: false, remaining: 0, last_used_at: nil}
    end

    test "reports the full set once generated" do
      RecoveryCodes.generate()

      assert %{generated?: true, remaining: 10, last_used_at: nil} = RecoveryCodes.status()
    end

    test "reports what is left after a code is spent" do
      [code | _rest] = RecoveryCodes.generate()
      {:ok, _remaining} = RecoveryCodes.redeem(code)

      assert %{generated?: true, remaining: 9, last_used_at: %DateTime{}} = RecoveryCodes.status()
    end
  end

  describe "discard/0" do
    test "leaves nothing that unlocks anything" do
      [code | _rest] = RecoveryCodes.generate()

      :ok = RecoveryCodes.discard()

      assert {:error, :invalid_code} = RecoveryCodes.redeem(code)
      refute RecoveryCodes.generated?()
    end
  end

  describe "entropy" do
    # Ten characters from a 32-symbol alphabet: fifty bits. Guessing one is not
    # the attack to worry about, but it should not be either.
    test "a code carries about fifty bits" do
      [code | _rest] = RecoveryCodes.generate()
      symbols = code |> String.replace("-", "") |> String.length()

      assert symbols == 10
      assert :math.log2(:math.pow(32, symbols)) >= 50
    end

    test "two sets do not overlap" do
      first = RecoveryCodes.generate()
      second = RecoveryCodes.generate()

      assert first -- second == first
    end
  end
end
