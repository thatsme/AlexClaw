defmodule AlexClaw.ReleaseOldKeyTest do
  @moduledoc """
  The rotation key is read in one place, and a missing one says so.

  Since 0.3.47 compose passes `OLD_SECRET_KEY_BASE: ${OLD_SECRET_KEY_BASE:-}`,
  so outside a rotation the variable is SET, to "". `fetch_env!/1` used to
  stop a mistaken `rekey()` at once, naming the variable; with an empty
  string it tried the empty key, failed to decrypt, and rolled back with a
  decrypt error that says nothing about the cause.

  `AlexClaw.Release.old_secret_key_base!/0` treats unset and empty the same:
  it raises, naming OLD_SECRET_KEY_BASE, before anything is read or written.
  `rekey/0` gets the old key only through it.
  """
  use ExUnit.Case, async: false
  @moduletag :unit

  alias AlexClaw.Release

  setup do
    previous = System.get_env("OLD_SECRET_KEY_BASE")

    on_exit(fn ->
      if previous,
        do: System.put_env("OLD_SECRET_KEY_BASE", previous),
        else: System.delete_env("OLD_SECRET_KEY_BASE")
    end)
  end

  defp message_of(fun) do
    fun.()
    flunk("expected old_secret_key_base!/0 to raise")
  rescue
    e -> Exception.message(e)
  end

  test "unset: raises naming the variable" do
    System.delete_env("OLD_SECRET_KEY_BASE")
    assert message_of(&Release.old_secret_key_base!/0) =~ "OLD_SECRET_KEY_BASE"
  end

  test "empty, as compose passes it outside a rotation: raises naming the variable" do
    System.put_env("OLD_SECRET_KEY_BASE", "")
    assert message_of(&Release.old_secret_key_base!/0) =~ "OLD_SECRET_KEY_BASE"
  end

  test "whitespace only counts as empty" do
    System.put_env("OLD_SECRET_KEY_BASE", "   ")
    assert message_of(&Release.old_secret_key_base!/0) =~ "OLD_SECRET_KEY_BASE"
  end

  test "set: returns it" do
    System.put_env("OLD_SECRET_KEY_BASE", String.duplicate("k", 64))
    assert Release.old_secret_key_base!() == String.duplicate("k", 64)
  end

  test "rekey reads the old key only through old_secret_key_base!/0" do
    source = File.read!("lib/alex_claw/release.ex")
    reads = Regex.scan(~r/(?:get_env|fetch_env!?)\(\s*"OLD_SECRET_KEY_BASE"/, source)

    assert source =~ ~r/def old_secret_key_base!/

    assert length(reads) == 1,
           "OLD_SECRET_KEY_BASE is read #{length(reads)} times in release.ex; expected once, inside old_secret_key_base!/0"
  end
end
