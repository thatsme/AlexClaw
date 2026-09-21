defmodule AlexClawWeb.AdminLive.DatabaseRestoreTest do
  @moduledoc """
  The Database page offers no restore until 0.3.34: no form, and a restore
  event sent anyway is refused and audited — with or without an elevation.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.Auth.{AuditEntry, Elevation}
  alias AlexClaw.Repo

  setup do
    sid = Elevation.new_sid()
    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
    {:ok, sid: sid}
  end

  defp open(conn, sid) do
    {:ok, view, html} = conn |> authenticate(sid) |> live("/database")
    {view, html}
  end

  defp refusals do
    Repo.all(
      from(e in AuditEntry,
        where: e.decision == "deny" and like(e.reason, "%disabled%database restore%")
      )
    )
  end

  test "the page offers no restore, and says why", %{conn: conn, sid: sid} do
    {view, html} = open(conn, sid)

    refute has_element?(view, "#restore-form")
    assert html =~ "operator procedure until 0.3.34"
  end

  test "a restore event sent anyway is refused and audited", %{conn: conn, sid: sid} do
    {view, _html} = open(conn, sid)

    render_click(view, "restore", %{})

    assert [_row] = refusals()
  end

  test "an elevation changes nothing", %{conn: conn, sid: sid} do
    AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    {:ok, _} = Elevation.grant(sid)
    {view, _html} = open(conn, sid)

    render_click(view, "restore", %{})

    assert [_row] = refusals()
  end
end
