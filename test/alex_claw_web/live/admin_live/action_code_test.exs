defmodule AlexClawWeb.AdminLive.ActionCodeTest do
  @moduledoc """
  Per-action gates, confirmed by typing the code on the page.

  These are the gates an elevation deliberately does not satisfy. Each one asks
  for a code of its own, and until now the only place to type it was a gateway
  — which made a bot the thing standing between an operator and their own
  skills. The action itself is performed by the same `execute_2fa_action/2`
  either way; only the place the code is typed differs.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Challenge, ChallengeStore, CodeAttempts, Elevation, TOTP}
  alias AlexClaw.Workflows

  setup do
    CodeAttempts.reset()
    sid = Elevation.new_sid()

    on_exit(fn ->
      Elevation.revoke(sid)
      CodeAttempts.reset()
      Challenge.drop_for_session(sid)
    end)

    {:ok, sid: sid, secret: enable_totp_without_gateway()}
  end

  # No chat id anywhere: the point is that a code can still be given.
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

  defp open(conn, sid, page) do
    {:ok, view, _html} =
      conn
      |> authenticate()
      |> Plug.Conn.put_session(:elevation_sid, sid)
      |> live(page)

    view
  end

  defp code(secret), do: NimbleTOTP.verification_code(secret)

  defp workflow(requires_2fa) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "action-code-#{System.unique_integer([:positive])}",
        enabled: true,
        metadata: %{"requires_2fa" => requires_2fa}
      })

    workflow
  end

  describe "the field appears for every per-action gate" do
    test "unloading a skill", ctx do
      view = open(ctx.conn, ctx.sid, "/skills")

      html = render_click(view, "unload_skill", %{"name" => "echo"})

      assert html =~ "Confirm:"
      assert html =~ "Unload skill: echo"
      assert html =~ "Code from your authenticator"
    end

    test "reloading a skill", ctx do
      view = open(ctx.conn, ctx.sid, "/skills")

      html = render_click(view, "reload_skill", %{"name" => "echo"})

      assert html =~ "Reload skill: echo"
    end

    test "running a workflow that requires a second factor", ctx do
      wf = workflow(true)
      view = open(ctx.conn, ctx.sid, "/workflows")

      html = render_click(view, "run_now", %{"id" => to_string(wf.id)})

      assert html =~ "Confirm:"
      assert html =~ "Run workflow: #{wf.name}"
    end

    test "but not for a workflow that does not require one", ctx do
      wf = workflow(false)
      view = open(ctx.conn, ctx.sid, "/workflows")

      html = render_click(view, "run_now", %{"id" => to_string(wf.id)})

      refute html =~ "Confirm:"
    end
  end

  describe "a correct code" do
    test "performs the action through execute_2fa_action", ctx do
      wf = workflow(true)
      view = open(ctx.conn, ctx.sid, "/workflows")
      render_click(view, "run_now", %{"id" => to_string(wf.id)})

      assert {:ok, _action} = Challenge.pending_for_session(ctx.sid)

      html = render_submit(view, "submit_action_code", %{"code" => code(ctx.secret)})

      # The field is gone and the action is no longer waiting: it ran.
      refute html =~ "Code from your authenticator"
      assert Challenge.pending_for_session(ctx.sid) == :error
    end

    test "consumes the waiting action, so it cannot be performed twice", ctx do
      wf = workflow(true)
      view = open(ctx.conn, ctx.sid, "/workflows")
      render_click(view, "run_now", %{"id" => to_string(wf.id)})

      render_submit(view, "submit_action_code", %{"code" => code(ctx.secret)})

      assert Challenge.pending_for_session(ctx.sid) == :error,
             "the action was left waiting after it had been performed"
    end

    test "withdraws the same challenge from the gateway", ctx do
      chat = "chat-#{System.unique_integer([:positive])}"
      AlexClaw.Config.set("telegram.chat_id", chat, type: "string", category: "telegram")

      wf = workflow(true)
      view = open(ctx.conn, ctx.sid, "/workflows")
      render_click(view, "run_now", %{"id" => to_string(wf.id)})

      assert Challenge.pending?(chat), "the gateway prompt was never raised"

      render_submit(view, "submit_action_code", %{"code" => code(ctx.secret)})

      refute Challenge.pending?(chat),
             "the gateway challenge outlived the code that answered it — a later code " <>
               "would perform the action a second time"
    end
  end

  describe "a wrong code" do
    test "does not perform the action, and leaves it waiting", ctx do
      wf = workflow(true)
      view = open(ctx.conn, ctx.sid, "/workflows")
      render_click(view, "run_now", %{"id" => to_string(wf.id)})

      html = render_submit(view, "submit_action_code", %{"code" => "000000"})

      assert html =~ "not valid"
      assert {:ok, _action} = Challenge.pending_for_session(ctx.sid)
    end

    test "counts against the same limits as an elevation code", ctx do
      wf = workflow(true)
      view = open(ctx.conn, ctx.sid, "/workflows")
      render_click(view, "run_now", %{"id" => to_string(wf.id)})

      for wrong <- ~w(000000 000001 000002) do
        render_submit(view, "submit_action_code", %{"code" => wrong})
      end

      assert {:locked, :session, _until} = CodeAttempts.status(ctx.sid)
    end
  end

  describe "an elevation" do
    # The rule this whole design turns on: a window earned for editing settings
    # is not authority to run a 2FA workflow or load a skill.
    test "does not satisfy a per-action gate", ctx do
      {:ok, _expires_at} = Elevation.grant(ctx.sid)
      wf = workflow(true)
      view = open(ctx.conn, ctx.sid, "/workflows")

      html = render_click(view, "run_now", %{"id" => to_string(wf.id)})

      assert html =~ "Confirm:",
             "an elevated session skipped the per-action code"
    end
  end

  describe "cancelling" do
    test "drops the waiting action", ctx do
      wf = workflow(true)
      view = open(ctx.conn, ctx.sid, "/workflows")
      render_click(view, "run_now", %{"id" => to_string(wf.id)})

      render_click(view, "cancel_action_code", %{})

      assert Challenge.pending_for_session(ctx.sid) == :error
    end
  end

  describe "expiry" do
    test "a code arriving after two minutes confirms nothing", ctx do
      wf = workflow(true)
      view = open(ctx.conn, ctx.sid, "/workflows")
      render_click(view, "run_now", %{"id" => to_string(wf.id)})

      # Age the stored challenge past its deadline, in the owner that holds it.
      {:ok, challenge} = ChallengeStore.fetch({:web, ctx.sid})
      past = System.monotonic_time(:second) - 1
      ChallengeStore.put({:web, ctx.sid}, %{challenge | expires_at: past})

      html = render_submit(view, "submit_action_code", %{"code" => code(ctx.secret)})

      assert html =~ "expired"
    end
  end
end
