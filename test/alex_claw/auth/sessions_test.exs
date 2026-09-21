defmodule AlexClaw.Auth.SessionsTest do
  @moduledoc """
  The server's answer to "is this login still good": a row every node reads,
  opened at login, closed at logout, eight hours at most, and only under the
  admin password it was opened with.

  The admin password is global configuration, so this does not run beside
  anything else.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AdminSession, AuditEntry, Elevation, Sessions}

  @max Sessions.max_age_seconds()

  setup do
    previous = Application.get_env(:alex_claw, :admin_password)
    Application.put_env(:alex_claw, :admin_password, "sessions-password")
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:alex_claw, :admin_password)
  defp restore(value), do: Application.put_env(:alex_claw, :admin_password, value)

  defp sid, do: Elevation.new_sid()
  defp rows, do: Repo.aggregate(AdminSession, :count)

  describe "a login" do
    test "is valid once opened, and not once closed" do
      s = sid()
      :ok = Sessions.open(s)
      assert Sessions.valid?(s)

      :ok = Sessions.close(s)
      refute Sessions.valid?(s)
      assert Sessions.close(s) == :ok
      assert Sessions.close(nil) == :ok
    end

    test "lasts eight hours from opening, and not a second longer" do
      s = sid()
      opened = System.system_time(:second) - 100
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

    # Reading the table must sign nobody in.
    test "the sid itself is never stored" do
      s = sid()
      :ok = Sessions.open(s)

      [row] = Repo.all(AdminSession)
      refute row.token_hash == s
      assert row.token_hash == :crypto.hash(:sha256, s)
      refute row.password_fingerprint =~ "sessions-password"
    end

    test "the socket id names the login by fingerprint, never by the sid" do
      s = sid()
      refute Sessions.socket_id(s) =~ s
      assert Sessions.socket_id(s) == "admin_session:" <> Elevation.fingerprint(s)
    end
  end

  describe "changing the admin password" do
    test "ends every login opened under the old one" do
      [a, b] = [sid(), sid()]
      :ok = Sessions.open(a)
      :ok = Sessions.open(b)

      Application.put_env(:alex_claw, :admin_password, "rotated-password")

      refute Sessions.valid?(a)
      refute Sessions.valid?(b)
    end

    test "leaves logins opened under the new one valid" do
      Application.put_env(:alex_claw, :admin_password, "rotated-password")
      s = sid()
      :ok = Sessions.open(s)

      assert Sessions.valid?(s)
    end
  end

  describe "sweep/1" do
    test "deletes only the logins that have expired" do
      now = System.system_time(:second)
      [expired, boundary, fresh] = [sid(), sid(), sid()]
      :ok = Sessions.open(expired, now - @max - 60)
      :ok = Sessions.open(boundary, now - @max)
      :ok = Sessions.open(fresh, now - 60)

      assert Sessions.sweep(now) == 2
      assert rows() == 1
      assert Sessions.valid?(fresh)
    end

    test "on an empty table deletes nothing" do
      assert Sessions.sweep() == 0
    end
  end

  describe "close_others/2" do
    test "ends every other login, keeps the one named, and records why" do
      [keep, other, another] = [sid(), sid(), sid()]
      for s <- [keep, other, another], do: :ok = Sessions.open(s)

      Phoenix.PubSub.subscribe(AlexClaw.PubSub, Sessions.socket_id(other))
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, Sessions.socket_id(keep))

      assert Sessions.close_others(keep, "test reason") == {:ok, 2}

      assert Sessions.valid?(keep)
      refute Sessions.valid?(other)
      refute Sessions.valid?(another)

      other_id = Sessions.socket_id(other)
      keep_id = Sessions.socket_id(keep)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^other_id, event: "disconnect"}
      refute_receive %Phoenix.Socket.Broadcast{topic: ^keep_id, event: "disconnect"}

      assert Repo.exists?(
               from(e in AuditEntry,
                 where: e.decision == "outcome" and like(e.reason, "%signed out: test reason%")
               )
             )
    end

    test "keeping none ends them all" do
      for _ <- 1..3, do: :ok = Sessions.open(sid())

      assert Sessions.close_others(nil, "no one to keep") == {:ok, 3}
      assert rows() == 0
    end
  end
end
