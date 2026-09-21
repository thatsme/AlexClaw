defmodule AlexClaw.Auth.SessionsTest do
  @moduledoc """
  The server's answer to "is this login still good": opened at login, closed
  at logout, eight hours at most, and writable only by its owner.
  """
  use ExUnit.Case, async: true

  alias AlexClaw.Auth.{Elevation, Sessions}

  @max Sessions.max_age_seconds()

  defp sid, do: Elevation.new_sid()

  test "an opened login is valid" do
    s = sid()
    :ok = Sessions.open(s)
    assert Sessions.valid?(s)
  end

  test "a closed login is not, and closing twice or closing nil is fine" do
    s = sid()
    :ok = Sessions.open(s)
    :ok = Sessions.close(s)

    refute Sessions.valid?(s)
    assert Sessions.close(s) == :ok
    assert Sessions.close(nil) == :ok
  end

  test "a login is valid for eight hours from opening, and not a second longer" do
    s = sid()
    opened = 1_000_000
    :ok = Sessions.open(s, opened)

    assert Sessions.valid?(s, opened)
    assert Sessions.valid?(s, opened + @max - 1)
    refute Sessions.valid?(s, opened + @max)
    refute Sessions.valid?(s, opened + @max + 1)
  end

  test "nothing that is not a sid the server opened is valid" do
    refute Sessions.valid?(nil)
    refute Sessions.valid?("")
    refute Sessions.valid?(sid())
    refute Sessions.valid?(%{"authenticated" => true})
  end

  test "the table cannot be written from outside its owner" do
    assert_raise ArgumentError, fn -> :ets.insert(:admin_sessions, {sid(), 0}) end
  end

  test "the socket id names the login by fingerprint, never by the sid" do
    s = sid()
    refute Sessions.socket_id(s) =~ s
    assert Sessions.socket_id(s) == "admin_session:" <> Elevation.fingerprint(s)
  end
end
