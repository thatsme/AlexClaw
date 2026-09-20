defmodule AlexClawWeb.AdminLive.DatabaseRestoreTest do
  @moduledoc """
  A restore is arbitrary SQL against the live database.

  It is therefore challenged per action: an elevation earned for editing a
  setting must not also authorise replacing the database, which is the one case
  where the fifteen-minute window deliberately buys nothing.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AuditLog, Elevation, TOTP}

  setup do
    sid = Elevation.new_sid()
    # A challenged restore leaves its file staged on purpose — the code may be
    # answered minutes later — so each test cleans up only what it staged.
    already_staged = staged_files()

    on_exit(fn ->
      Elevation.revoke(sid)

      for file <- staged_files() -- already_staged do
        File.rm(Path.join(System.tmp_dir!(), file))
      end
    end)

    {:ok, sid: sid, already_staged: already_staged}
  end

  defp enable_totp_with_gateway do
    AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    chat_id = "chat_#{System.unique_integer([:positive])}"
    AlexClaw.Config.set("telegram.chat_id", chat_id, type: "string", category: "telegram")
    chat_id
  end

  defp open(conn, sid) do
    {:ok, view, html} =
      conn
      |> authenticate()
      |> Plug.Conn.put_session(:elevation_sid, sid)
      |> live("/database")

    {view, html}
  end

  defp upload_dump(view) do
    dump =
      file_input(view, "#restore-form", :dump_file, [
        %{name: "dump.sql", content: "SELECT 1;", type: "application/sql"}
      ])

    render_upload(dump, "dump.sql")
  end

  describe "with 2FA configured" do
    test "a restore is challenged rather than performed", %{conn: conn, sid: sid} do
      chat_id = enable_totp_with_gateway()
      {view, _html} = open(conn, sid)
      upload_dump(view)

      render_click(view, "restore", %{})

      assert TOTP.pending_challenge?(chat_id),
             "the restore ran without asking for a code"
    end

    # The point of the per-action rule: an unlock earned on the Config page is
    # not authority to replace the database.
    test "an elevated session is challenged all the same", %{conn: conn, sid: sid} do
      chat_id = enable_totp_with_gateway()
      {:ok, _expires_at} = Elevation.grant(sid)
      {view, _html} = open(conn, sid)
      upload_dump(view)

      render_click(view, "restore", %{})

      assert TOTP.pending_challenge?(chat_id),
             "an elevation covered a restore, which it must never do"
    end

    test "the page says so instead of offering an unlock", %{conn: conn, sid: sid} do
      enable_totp_with_gateway()

      {_view, html} = open(conn, sid)

      assert html =~ "challenged every time"
      refute html =~ "Unlock editing"
    end
  end

  describe "with 2FA enabled but no gateway" do
    test "the restore asks for a code on the page instead of refusing", ctx do
      %{conn: conn, sid: sid} = ctx

      AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
        type: "string",
        category: "auth"
      )

      AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
      AlexClaw.Config.set("telegram.chat_id", "", type: "string", category: "telegram")
      AlexClaw.Config.set("discord.channel_id", "", type: "string", category: "discord")

      {view, _html} = open(conn, sid)
      upload_dump(view)

      html = render_click(view, "restore", %{})

      # The field is offered, and nothing has run: a restore waits for its code
      # whether or not a gateway exists to prompt on.
      assert html =~ "Confirm:"
      assert html =~ "Restore the database from"
      assert html =~ "Code from your authenticator"
    end
  end

  # Strict: with no second factor there is no password-only path to a restore.
  # This is the one write where that matters most — it is arbitrary SQL.
  describe "with no second factor configured" do
    test "the page says the control plane is read-only", %{conn: conn, sid: sid} do
      {_view, html} = open(conn, sid)

      assert html =~ "Read-only — 2FA is not configured"
      assert html =~ "Two-factor authentication"
    end

    test "a restore is refused rather than performed", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      upload_dump(view)

      render_click(view, "restore", %{})

      # Nothing ran, and the upload was not left waiting for a code that cannot
      # be asked for.
      assert staged_files() == ctx.already_staged
    end

    test "the refusal is recorded with its reason", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      upload_dump(view)

      render_click(view, "restore", %{})

      refusal = AuditLog.recent(limit: 1, decision: "deny") |> List.first()

      assert refusal.reason =~ "no_second_factor"
      assert refusal.reason =~ "database restore"
    end
  end

  defp staged_files do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "alexclaw-restore-"))
  end
end
