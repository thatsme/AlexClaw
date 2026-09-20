defmodule AlexClawWeb.AdminLive.WebCodeEntryTest do
  @moduledoc """
  Elevating by typing the code where you already are.

  The second factor is the authenticator app. A gateway is somewhere convenient
  to type the code, so an instance with no gateway at all must still be able to
  unlock — that is the case these tests lead with.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{CodeAttempts, Elevation}

  setup do
    CodeAttempts.reset()
    sid = Elevation.new_sid()

    on_exit(fn ->
      Elevation.revoke(sid)
      CodeAttempts.reset()
    end)

    {:ok, sid: sid, secret: enable_totp_without_gateway()}
  end

  # Deliberately no telegram.chat_id and no discord.channel_id: nothing could
  # receive a challenge, and the code field must work anyway.
  defp enable_totp_without_gateway do
    secret = NimbleTOTP.secret()

    AlexClaw.Config.set("auth.totp.secret", Base.encode32(secret, padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    AlexClaw.Config.set("telegram.chat_id", "", type: "string", category: "telegram")
    AlexClaw.Config.set("discord.channel_id", "", type: "string", category: "discord")
    AlexClaw.Config.delete("auth.totp.last_used_at")

    secret
  end

  defp open(conn, sid, page \\ "/config") do
    {:ok, view, html} =
      conn
      |> authenticate()
      |> Plug.Conn.put_session(:elevation_sid, sid)
      |> live(page)

    {view, html}
  end

  defp code(secret), do: NimbleTOTP.verification_code(secret)

  describe "with no gateway configured at all" do
    test "the code field unlocks the session", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)

      render_click(view, "unlock_editing", %{})
      render_submit(view, "submit_code", %{"code" => code(ctx.secret)})

      assert Elevation.elevated?(ctx.sid)
    end

    test "and a control-plane write then goes through", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)

      render_click(view, "unlock_editing", %{})
      render_submit(view, "submit_code", %{"code" => code(ctx.secret)})

      render_click(view, "save", %{
        "key" => "web.entry.probe",
        "value" => "written",
        "type" => "string",
        "category" => "general"
      })

      assert AlexClaw.Config.get("web.entry.probe") == "written"
    end

    test "the page offers the field rather than only a gateway prompt", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)

      html = render_click(view, "unlock_editing", %{})

      assert html =~ "Code from your authenticator"
      assert html =~ "Send the prompt to my gateway instead"
    end
  end

  describe "a wrong code" do
    test "does not elevate, and says so", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      render_click(view, "unlock_editing", %{})

      html = render_submit(view, "submit_code", %{"code" => "000000"})

      refute Elevation.elevated?(ctx.sid)
      assert html =~ "not valid"
    end

    test "counts against the session", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      render_click(view, "unlock_editing", %{})

      render_submit(view, "submit_code", %{"code" => "000000"})

      assert CodeAttempts.status(ctx.sid) == :ok
      render_submit(view, "submit_code", %{"code" => "000001"})
      render_submit(view, "submit_code", %{"code" => "000002"})

      assert {:locked, :session, _until} = CodeAttempts.status(ctx.sid)
    end

    test "locks the field after three, and refuses a correct code while locked", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      render_click(view, "unlock_editing", %{})

      for wrong <- ~w(000000 000001 000002) do
        render_submit(view, "submit_code", %{"code" => wrong})
      end

      render_submit(view, "submit_code", %{"code" => code(ctx.secret)})

      refute Elevation.elevated?(ctx.sid),
             "a locked session accepted a correct code — the lock is not a lock"
    end
  end

  describe "the instance limit" do
    test "locks code entry for a session that never guessed", ctx do
      for n <- 1..CodeAttempts.instance_limit(), do: CodeAttempts.record_failure("sid-#{n}")

      {view, _html} = open(ctx.conn, ctx.sid)
      render_click(view, "unlock_editing", %{})
      render_submit(view, "submit_code", %{"code" => code(ctx.secret)})

      refute Elevation.elevated?(ctx.sid)
    end

    test "says so on the page", ctx do
      for n <- 1..CodeAttempts.instance_limit(), do: CodeAttempts.record_failure("sid-#{n}")

      {_view, html} = open(ctx.conn, ctx.sid)

      assert html =~ "Code entry locked"
      assert html =~ "across sessions"
    end

    test "notifies a reachable gateway once", ctx do
      AlexClaw.RecordingGateway.install()

      for n <- 1..CodeAttempts.instance_limit(), do: CodeAttempts.record_failure("sid-#{n}")

      messages = AlexClaw.RecordingGateway.sent()

      assert Enum.count(messages, &(&1 =~ "code entry")) == 1,
             "expected exactly one lockout notification, got: #{inspect(messages)}"

      # And going on guessing does not turn the notice into the flood.
      CodeAttempts.record_failure("sid-again")
      assert Enum.count(AlexClaw.RecordingGateway.sent(), &(&1 =~ "code entry")) == 1
      assert ctx.sid
    end
  end

  describe "replay" do
    # The code is valid for its whole thirty-second period. Accepting it twice
    # would make shoulder-surfing enough.
    test "a code already used is refused the second time", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      render_click(view, "unlock_editing", %{})
      used = code(ctx.secret)

      render_submit(view, "submit_code", %{"code" => used})
      assert Elevation.elevated?(ctx.sid)

      :ok = Elevation.revoke(ctx.sid)
      render_submit(view, "submit_code", %{"code" => used})

      refute Elevation.elevated?(ctx.sid),
             "a replayed code elevated the session a second time"
    end
  end

  describe "the gateway path" do
    test "is still offered, and still works", ctx do
      AlexClaw.Config.set("telegram.chat_id", "chat-#{System.unique_integer([:positive])}",
        type: "string",
        category: "telegram"
      )

      {view, _html} = open(ctx.conn, ctx.sid)
      render_click(view, "unlock_editing", %{})

      html = render_click(view, "request_gateway_code", %{})

      assert html =~ "authenticator" or html =~ "2FA code requested"
    end
  end

  describe "cancelling" do
    test "closes the field without elevating", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      render_click(view, "unlock_editing", %{})

      html = render_click(view, "cancel_code", %{})

      refute html =~ "Code from your authenticator"
      refute Elevation.elevated?(ctx.sid)
    end
  end

  describe "codes with spaces" do
    test "are accepted as typed by an authenticator that groups digits", ctx do
      {view, _html} = open(ctx.conn, ctx.sid)
      render_click(view, "unlock_editing", %{})
      spaced = ctx.secret |> code() |> String.replace(~r/(\d{3})(\d{3})/, "\\1 \\2")

      render_submit(view, "submit_code", %{"code" => spaced})

      assert Elevation.elevated?(ctx.sid)
    end
  end

  describe "TOTP not configured" do
    test "the field is not the way in — the page says to set 2FA up", ctx do
      AlexClaw.Config.set("auth.totp.enabled", "false", type: "boolean", category: "auth")

      {_view, html} = open(ctx.conn, ctx.sid)

      assert html =~ "Read-only"
      assert html =~ "Two-factor authentication"
    end
  end
end
