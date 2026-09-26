defmodule AlexClawWeb.AdminLive.PrivilegedRunPromptTest do
  @moduledoc """
  The admin UI's code prompt for a run with a privileged step is not sent to
  the chat (S9 fix review, ruling on N5): only the admin UI's code can make
  that run privileged, so a chat that answered would only be refused. A
  protected workflow with no privileged step still prompts the chat.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  import Phoenix.LiveViewTest

  alias AlexClaw.Auth.Challenge
  alias AlexClaw.Workflows

  setup do
    AlexClaw.Config.set("shell.enabled", "true", type: "boolean", category: "shell")

    AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    chat = "chat_#{System.unique_integer([:positive])}"
    AlexClaw.Config.set("telegram.chat_id", chat, type: "string", category: "telegram")
    %{chat: chat}
  end

  defp workflow(protected, steps) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "prompt-#{System.unique_integer([:positive])}",
        enabled: true,
        metadata: %{"requires_2fa" => protected}
      })

    for step <- steps, do: {:ok, _} = Workflows.add_step(wf, step)
    wf
  end

  defp click_run(conn, workflow) do
    {:ok, view, _html} = conn |> authenticate() |> live("/workflows")

    view
    |> element(~s{[phx-click="run_now"][phx-value-id="#{workflow.id}"]})
    |> render_click()
  end

  test "a protected run with a privileged step does not prompt the chat", %{
    conn: conn,
    chat: chat
  } do
    wf =
      workflow(true, [%{name: "Shell", skill: "shell", config: %{"command" => "uptime"}}])

    click_run(conn, wf)

    refute Challenge.pending?(chat)
  end

  test "a protected run with no privileged step still prompts the chat", %{conn: conn, chat: chat} do
    wf = workflow(true, [])

    click_run(conn, wf)

    assert Challenge.pending?(chat)
  end
end
