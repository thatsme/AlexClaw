defmodule AlexClawWeb.SessionRevocationTest do
  @moduledoc """
  A LiveView page must stop working when its login does.

  The page's signed token carries a copy of the session as it was when the
  page was rendered, and LiveView accepts that token for two weeks. A mount
  that trusts the copy lets a page rendered before logout, or before the
  session expired, connect afterwards. These tests hold a page rendered while
  signed in and try to use it once the login is gone.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Elevation, Sessions}

  setup do
    # Put back what was there: since 0.4.0 config/test.exs sets an admin
    # password, and deleting it would leave later tests with none.
    previous = Application.fetch_env(:alex_claw, :admin_password)
    Application.put_env(:alex_claw, :admin_password, "revocation-password")

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:alex_claw, :admin_password, v)
        :error -> Application.delete_env(:alex_claw, :admin_password)
      end
    end)

    :ok
  end

  defp signed_in do
    build_conn()
    |> post("/login", %{"password" => "revocation-password"})
    |> recycle()
  end

  test "a page rendered before logout cannot connect after it" do
    conn = signed_in()
    rendered = get(conn, "/config")
    assert html_response(rendered, 200)

    post(conn, "/logout")

    assert {:error, {:redirect, %{to: "/login"}}} = live(rendered)
  end

  test "a page rendered while the login was fresh cannot connect once it has expired" do
    sid = Elevation.new_sid()
    rendered = build_conn() |> authenticate(sid) |> get("/config")
    assert html_response(rendered, 200)

    # The same login, now past its eight hours: closed, and opened again as of
    # nine hours ago, since a sid holds one row.
    :ok = Sessions.close(sid)
    :ok = Sessions.open(sid, System.system_time(:second) - 9 * 60 * 60)

    assert {:error, {:redirect, %{to: "/login"}}} = live(rendered)
  end

  test "a page whose login the server never opened cannot connect" do
    rendered = build_conn() |> authenticate() |> get("/config")
    sid = get_session(rendered, :elevation_sid)
    :ok = Sessions.close(sid)

    assert {:error, {:redirect, %{to: "/login"}}} = live(rendered)
  end

  # Phoenix closes every socket of a login when "disconnect" is broadcast on
  # the login's live_socket_id; the websocket transport does the closing, and
  # LiveViewTest has no transport to close. What is ours to get right is that
  # the id is set at login and that logout broadcasts on exactly that topic —
  # a reconnect afterwards is then refused by the mount, as tested above.
  test "logout disconnects every open page of that login, and only that login" do
    conn = signed_in()
    other = signed_in()
    socket_id = get_session(get(conn, "/config"), :live_socket_id)
    other_id = get_session(get(other, "/config"), :live_socket_id)

    assert is_binary(socket_id)
    refute socket_id == other_id

    AlexClawWeb.Endpoint.subscribe(socket_id)
    AlexClawWeb.Endpoint.subscribe(other_id)

    post(conn, "/logout")

    assert_receive %Phoenix.Socket.Broadcast{topic: ^socket_id, event: "disconnect"}
    refute_receive %Phoenix.Socket.Broadcast{topic: ^other_id, event: "disconnect"}
  end
end
