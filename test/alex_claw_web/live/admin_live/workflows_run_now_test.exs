defmodule AlexClawWeb.AdminLive.WorkflowsRunNowTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  import Phoenix.LiveViewTest

  alias AlexClaw.Auth.TOTP
  alias AlexClaw.Workflows

  defp workflow(requires_2fa) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "run-now-#{System.unique_integer([:positive])}",
        enabled: true,
        metadata: %{"requires_2fa" => requires_2fa}
      })

    workflow
  end

  # Each test gets its own chat id. The challenge table is owned by a supervised
  # process and so persists for the whole suite; a shared id would let one test's
  # challenge decide another's assertion.
  defp gateway_chat do
    chat_id = "chat_#{System.unique_integer([:positive])}"
    AlexClaw.Config.set("telegram.chat_id", chat_id, type: "string", category: "telegram")
    chat_id
  end

  defp enable_totp_with_gateway do
    AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    gateway_chat()
  end

  defp click_run(conn, workflow) do
    {:ok, view, _html} = conn |> authenticate() |> live("/workflows")

    view
    |> element(~s{[phx-click="run_now"][phx-value-id="#{workflow.id}"]})
    |> render_click()
  end

  # Asserting on the challenge rather than the flash: flash is rendered by the
  # layout, and the challenge is the thing that actually gates the run.
  describe "run_now honours metadata requires_2fa" do
    test "a workflow without the flag is not challenged", %{conn: conn} do
      chat_id = enable_totp_with_gateway()
      wf = workflow(false)

      click_run(conn, wf)

      refute TOTP.pending_challenge?(chat_id)
    end

    # Previously this ran the workflow outright, bypassing the gate the gateway applies.
    test "a workflow with the flag raises a challenge instead of running", %{conn: conn} do
      chat_id = enable_totp_with_gateway()
      wf = workflow(true)

      click_run(conn, wf)

      assert TOTP.pending_challenge?(chat_id)
    end

    test "a flagged workflow raises no challenge when there is no second factor", %{conn: conn} do
      chat_id = gateway_chat()
      wf = workflow(true)

      click_run(conn, wf)

      refute TOTP.pending_challenge?(chat_id)
    end

    test "the page still renders after a gated click", %{conn: conn} do
      enable_totp_with_gateway()
      wf = workflow(true)

      assert click_run(conn, wf) =~ "Workflows"
    end
  end
end
