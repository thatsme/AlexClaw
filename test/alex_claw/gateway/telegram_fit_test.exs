defmodule AlexClaw.Gateway.TelegramFitTest do
  @moduledoc """
  Telegram refuses a message over 4096 characters, and the refusal meant the
  user received nothing — a failure report quoting a whole API response, for
  one. Messages are cut to fit, and say so.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Gateway.Telegram

  test "a message within the limit is sent as it is" do
    for text <- ["", "short", String.duplicate("é", 4096)] do
      assert Telegram.fit(text) == text
    end
  end

  test "a longer message is cut to the limit and marked" do
    fitted = Telegram.fit(String.duplicate("x", 10_000))
    assert String.length(fitted) == 4096
    assert String.ends_with?(fitted, "(message truncated)")
  end

  test "one character over is cut too" do
    assert String.length(Telegram.fit(String.duplicate("y", 4097))) == 4096
  end
end
