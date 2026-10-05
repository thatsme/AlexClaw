defmodule AlexClawWeb.AdminLive.ConnectionsPageTest do
  @moduledoc """
  The Connections page and the control plane behind it
  (reports/SQL_READ_PREMISES.md §4.1).

  - The TLS mode is chosen, never preselected; `require` says what it is:
    encrypted, the server's identity not verified.
  - A password typed into the page goes to OpenBao and never comes back: not
    in the page, not in the audit row.
  - A save through the control plane starts the connection's pool, a delete
    stops it; the Services page shows each connection's state.

  The gate itself (refused without an elevation, one refusal row each) is in
  `ElevationGateTest`.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{AuditLog, Elevation}
  alias AlexClaw.{Connections, ControlPlane}
  alias AlexClaw.Connections.Pools
  alias AlexClaw.ControlPlane.Context
  alias Ecto.Adapters.SQL.Sandbox

  @password "page-typed-Password-9"

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    sid = Elevation.new_sid()

    on_exit(fn ->
      Pools.stop_all()
      AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end)
    end)

    enable_totp()
    {:ok, sid: sid}
  end

  defp enable_totp do
    AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    AlexClaw.Config.set("telegram.chat_id", "123", type: "string", category: "telegram")
  end

  defp open(conn, sid, page) do
    {:ok, view, html} = conn |> authenticate(sid) |> live(page)
    {view, html}
  end

  defp form(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "page_#{System.unique_integer([:positive])}",
        "host" => "page-db.invalid",
        "port" => "5432",
        "database" => "erp",
        "username" => "reader",
        "tls_mode" => "require",
        "password" => @password
      },
      overrides
    )
  end

  defp tls_options(html) do
    {:ok, doc} = Floki.parse_document(html)
    Floki.find(doc, ~s(select[name="tls_mode"] option))
  end

  test "the TLS mode is chosen, never preselected", %{conn: conn, sid: sid} do
    {:ok, _} = Elevation.grant(sid)
    {view, _html} = open(conn, sid, "/connections")
    html = render_click(view, "toggle_form", %{})

    options = tls_options(html)
    values = for option <- options, do: option |> Floki.attribute("value") |> List.first()
    assert Enum.sort(values -- [""]) == ~w(disable require verify_full)

    # A browser shows the first option when none is selected: it must be the
    # empty, unselectable placeholder, never a mode.
    [placeholder | _modes] = options
    assert Floki.attribute(placeholder, "value") == [""]
    assert Floki.attribute(placeholder, "disabled") != []

    selected =
      for option <- options,
          Floki.attribute(option, "selected") != [],
          do: Floki.attribute(option, "value")

    assert selected in [[], [[""]]], "a TLS mode is preselected: #{inspect(selected)}"
  end

  test "require says the server's identity is not verified", %{conn: conn, sid: sid} do
    {view, _html} = open(conn, sid, "/connections")
    html = render_click(view, "toggle_form", %{})

    [label] =
      for option <- tls_options(html),
          Floki.attribute(option, "value") == ["require"],
          do: Floki.text(option)

    assert label =~ "encrypted, server identity not verified"
  end

  test "a password typed into the page goes to OpenBao and never comes back",
       %{conn: conn, sid: sid} do
    {:ok, _} = Elevation.grant(sid)
    {view, _html} = open(conn, sid, "/connections")
    params = form()

    html = render_submit(view, "save", params)
    assert {:ok, saved} = Connections.get_by_name(params["name"])
    refute html =~ @password

    edit = render_click(view, "edit", %{"id" => to_string(saved.id)})
    refute edit =~ @password
    {_view, reloaded} = open(conn, sid, "/connections")
    refute reloaded =~ @password

    [row | _] = AuditLog.recent(limit: 20, decision: "write")
    assert row.permission == "control_plane.save_connection"
    assert row.reason =~ params["name"]
    refute row.reason =~ @password
  end

  test "a save through the control plane starts the pool; a delete stops it", %{sid: sid} do
    {:ok, _} = Elevation.grant(sid)
    attrs = for {key, value} <- form(), into: %{}, do: {String.to_existing_atom(key), value}

    assert {:ok, saved} =
             ControlPlane.perform(
               :save_connection,
               %{attrs: attrs, detail: "connection saved: #{attrs.name}"},
               Context.admin_ui(sid)
             )

    assert %{name: name} = Pools.status(saved.name)
    assert name == saved.name

    assert {:ok, _} =
             ControlPlane.perform(
               :delete_connection,
               %{connection_id: saved.id, detail: "connection deleted: #{saved.name}"},
               Context.admin_ui(sid)
             )

    assert Pools.status(saved.name) == nil
  end

  test "the Services page shows each connection's state", %{conn: conn, sid: sid} do
    {:ok, _} = Elevation.grant(sid)
    attrs = for {key, value} <- form(), into: %{}, do: {String.to_existing_atom(key), value}

    {:ok, saved} =
      ControlPlane.perform(
        :save_connection,
        %{attrs: attrs, detail: "connection saved: #{attrs.name}"},
        Context.admin_ui(sid)
      )

    {_view, html} = open(conn, sid, "/services")
    assert html =~ saved.name
    assert html =~ "page-db.invalid"
    refute html =~ @password
  end
end
