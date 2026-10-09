defmodule AlexClawWeb.AdminLive.ConnectionsTlsLabelsTest do
  @moduledoc """
  The Connections page says what each weaker TLS mode costs the password
  (reports/SQLREAD_ATTACKER_REVIEW.md M4): AlexClaw's PostgreSQL client
  answers a server's request for the password in clear, so

  - `disable`: the password is readable on the network path;
  - `require`: encrypted, but a server that impersonates the real one can ask
    for the password and receive it.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.Elevation
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    sid = Elevation.new_sid()
    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
    {:ok, sid: sid}
  end

  defp label(conn, sid, mode) do
    {:ok, view, _html} = conn |> authenticate(sid) |> live("/connections")
    {:ok, doc} = view |> render_click("toggle_form", %{}) |> Floki.parse_document()

    [label] =
      for option <- Floki.find(doc, ~s(select[name="tls_mode"] option)),
          Floki.attribute(option, "value") == [mode],
          do: Floki.text(option)

    label
  end

  test "disable says the password is readable on the network path", %{conn: conn, sid: sid} do
    assert label(conn, sid, "disable") =~ "password readable on the network path"
  end

  test "require says an impostor can obtain the password", %{conn: conn, sid: sid} do
    assert label(conn, sid, "require") =~ "an impostor can obtain the password"
  end
end
