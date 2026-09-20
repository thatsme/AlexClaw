defmodule AlexClaw.Auth.ElevationTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.Elevation

  # Every test uses its own sid, because the table is process-wide and outlives
  # any one test.
  defp sid, do: Elevation.new_sid()

  describe "elevated?/1" do
    test "a session that never asked holds nothing" do
      refute Elevation.elevated?(sid())
    end

    # A session before login has no sid at all; that is not an error, it is the
    # common case on the login page itself.
    test "no session identifier is not elevated" do
      refute Elevation.elevated?(nil)
    end

    test "a granted session is elevated" do
      s = sid()
      {:ok, _expires_at} = Elevation.grant(s)

      assert Elevation.elevated?(s)
    end

    test "one session's grant says nothing about another's" do
      granted = sid()
      other = sid()
      {:ok, _} = Elevation.grant(granted)

      refute Elevation.elevated?(other)
    end
  end

  describe "the window" do
    test "is fifteen minutes from the moment the code was accepted" do
      s = sid()
      before = System.system_time(:second)

      {:ok, expires_at} = Elevation.grant(s)

      assert expires_at - before >= Elevation.window_seconds()
      assert expires_at - before <= Elevation.window_seconds() + 2
    end

    # The point of a fixed window: activity inside it does not extend it.
    test "has ended one second past the deadline, however busy the session was" do
      s = sid()
      {:ok, expires_at} = Elevation.grant(s)

      assert Elevation.elevated?(s, expires_at - 1)
      refute Elevation.elevated?(s, expires_at + 1)
    end

    test "is over at the deadline itself, not a second later" do
      s = sid()
      {:ok, expires_at} = Elevation.grant(s)

      refute Elevation.elevated?(s, expires_at)
    end

    test "a second grant starts a new window rather than extending the old one" do
      s = sid()
      {:ok, first} = Elevation.grant(s)
      {:ok, second} = Elevation.grant(s)

      assert second >= first
      refute Elevation.elevated?(s, second + 1)
    end
  end

  describe "revoke/1" do
    test "ends an elevation immediately" do
      s = sid()
      {:ok, _} = Elevation.grant(s)

      assert :ok = Elevation.revoke(s)
      refute Elevation.elevated?(s)
    end

    # Logout revokes unconditionally, including for sessions that never elevated.
    test "is a no-op for a session holding nothing" do
      assert :ok = Elevation.revoke(sid())
    end

    test "tolerates a session that never logged in" do
      assert :ok = Elevation.revoke(nil)
    end
  end

  describe "expiry sweep" do
    test "selects a session only once its deadline has passed" do
      s = sid()
      {:ok, expires_at} = Elevation.grant(s)

      refute s in Elevation.expired(expires_at - 1)
      assert s in Elevation.expired(expires_at)
      assert s in Elevation.expired(expires_at + 60)
    end

    test "leaves live sessions alone" do
      s = sid()
      {:ok, _} = Elevation.grant(s)

      refute s in Elevation.expired(System.system_time(:second))
    end
  end

  describe "expires_at/1" do
    test "reports the deadline of a live elevation" do
      s = sid()
      {:ok, expires_at} = Elevation.grant(s)

      assert Elevation.expires_at(s) == expires_at
    end

    test "is nil for a session holding none" do
      assert Elevation.expires_at(sid()) == nil
      assert Elevation.expires_at(nil) == nil
    end
  end

  describe "session identifiers" do
    test "are unique per login" do
      assert sid() != sid()
    end

    # 32 random bytes, url-encoded. Guessing one is guessing a session.
    test "carry 256 bits of entropy" do
      assert byte_size(Base.url_decode64!(sid(), padding: false)) == 32
    end

    test "a fingerprint does not reveal the identifier" do
      s = sid()
      print = Elevation.fingerprint(s)

      assert byte_size(print) == 16
      refute String.contains?(s, print)
      assert Elevation.fingerprint(s) == print
    end

    test "different sessions fingerprint differently" do
      refute Elevation.fingerprint(sid()) == Elevation.fingerprint(sid())
    end

    # The topic is broadcast on; it must not carry the credential either.
    test "the PubSub topic names the fingerprint, not the session" do
      s = sid()

      assert Elevation.topic(s) == "elevation:" <> Elevation.fingerprint(s)
      refute String.contains?(Elevation.topic(s), s)
    end
  end

  describe "grant/1" do
    # A caller without a sid is a programmer error, not a runtime condition:
    # every authenticated session has one from login.
    test "refuses anything that is not a session identifier" do
      assert_raise FunctionClauseError, fn -> Elevation.grant(nil) end
      assert_raise FunctionClauseError, fn -> Elevation.grant(:admin) end
    end

    test "tells subscribers when a session is elevated" do
      s = sid()
      :ok = Elevation.subscribe(s)

      {:ok, expires_at} = Elevation.grant(s)

      assert_receive {:elevation, :granted, ^expires_at}
    end

    test "tells subscribers when it is revoked" do
      s = sid()
      :ok = Elevation.subscribe(s)
      {:ok, _} = Elevation.grant(s)

      :ok = Elevation.revoke(s)

      assert_receive {:elevation, :ended, :revoked}
    end

    test "does not announce a revoke that ended nothing" do
      s = sid()
      :ok = Elevation.subscribe(s)

      :ok = Elevation.revoke(s)

      refute_receive {:elevation, :ended, _}, 50
    end
  end

  # Elevation is always required. What varies is whether the instance can
  # answer a challenge yet, which is what decides how a refusal reads.
  describe "configured?/0" do
    test "is false when no second factor is configured" do
      refute Elevation.configured?()
    end

    test "is true once TOTP is enabled" do
      AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
        type: "string",
        category: "auth"
      )

      AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")

      assert Elevation.configured?()
    end
  end
end
