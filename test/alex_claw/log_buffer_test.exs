defmodule AlexClaw.LogBufferTest do
  use ExUnit.Case, async: false

  alias AlexClaw.LogBuffer

  setup do
    LogBuffer.clear()
    :ok
  end

  describe "clear/0" do
    test "returns :ok" do
      assert :ok = LogBuffer.clear()
    end
  end

  describe "recent/1" do
    test "returns a list" do
      assert is_list(LogBuffer.recent())
    end

    test "accepts limit option" do
      entries = LogBuffer.recent(limit: 5)
      assert is_list(entries)
      assert length(entries) <= 5
    end

    test "accepts severity filter" do
      entries = LogBuffer.recent(severity: :high)
      assert is_list(entries)
      Enum.each(entries, fn entry -> assert entry.severity == :high end)
    end
  end

  describe "counts/0" do
    test "returns map with all severity keys" do
      counts = LogBuffer.counts()
      assert Map.has_key?(counts, :critical)
      assert Map.has_key?(counts, :high)
      assert Map.has_key?(counts, :moderate)
      assert Map.has_key?(counts, :low)
      assert Map.has_key?(counts, :circuit_breaker)
    end

    test "all counts are non-negative integers" do
      counts = LogBuffer.counts()
      for {_key, val} <- counts, do: assert(is_integer(val) and val >= 0)
    end
  end
end
