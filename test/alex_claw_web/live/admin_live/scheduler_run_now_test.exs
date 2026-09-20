defmodule AlexClawWeb.AdminLive.SchedulerRunNowTest do
  @moduledoc """
  The Scheduler page starts the same runs as the Workflows page.

  It used to start them without asking: `Executor.run/1` straight from the
  handler, while the Workflows page challenged a workflow marked requires_2fa.
  Same capability, two doors, one of them unlocked.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  import Phoenix.LiveViewTest

  alias AlexClaw.Auth.TOTP
  alias AlexClaw.Workflows

  defp workflow(requires_2fa) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "sched-#{System.unique_integer([:positive])}",
        enabled: true,
        schedule: "0 9 * * *",
        metadata: %{"requires_2fa" => requires_2fa}
      })

    workflow
  end

  # One chat per test: the challenge table outlives a test, so a shared id would
  # let one test's challenge answer another's assertion.
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

  defp run_now(conn, workflow) do
    {:ok, view, _html} = conn |> authenticate() |> live("/scheduler")
    render_click(view, "run_now", %{"id" => to_string(workflow.id)})
  end

  describe "run_now from the Scheduler page" do
    test "challenges a workflow that requires 2FA", %{conn: conn} do
      chat_id = enable_totp_with_gateway()
      wf = workflow(true)

      run_now(conn, wf)

      assert TOTP.pending_challenge?(chat_id),
             "the Scheduler page started a 2FA workflow without a challenge"
    end

    test "does not challenge a workflow that does not require it", %{conn: conn} do
      chat_id = enable_totp_with_gateway()
      wf = workflow(false)

      run_now(conn, wf)

      refute TOTP.pending_challenge?(chat_id)
    end

    # The rule is the workflow's own flag, so both pages reach the same verdict
    # on the same workflow. That is the property the shared function exists for.
    test "reaches the same verdict as the Workflows page", %{conn: conn} do
      from_workflows_chat = enable_totp_with_gateway()
      wf = workflow(true)

      {:ok, workflows_view, _html} = conn |> authenticate() |> live("/workflows")
      render_click(workflows_view, "run_now", %{"id" => to_string(wf.id)})

      # A second chat, so the two challenges cannot be mistaken for each other.
      from_scheduler_chat = enable_totp_with_gateway()
      run_now(conn, wf)

      assert TOTP.pending_challenge?(from_workflows_chat) ==
               TOTP.pending_challenge?(from_scheduler_chat)

      assert TOTP.pending_challenge?(from_scheduler_chat)
    end

    test "reports a workflow that is gone rather than crashing", %{conn: conn} do
      enable_totp_with_gateway()

      {:ok, view, _html} = conn |> authenticate() |> live("/scheduler")

      assert render_click(view, "run_now", %{"id" => "999999"})
    end

    test "reports an id that is not a number", %{conn: conn} do
      {:ok, view, _html} = conn |> authenticate() |> live("/scheduler")

      assert render_click(view, "run_now", %{"id" => "not-an-id"})
    end
  end
end
