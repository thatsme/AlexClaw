defmodule AlexClaw.Workflows.PrivilegedRunUpFrontTest do
  @moduledoc """
  A run that has a privileged step and cannot be privileged is refused up
  front, with the reason, before anything runs (S9 fix review, ruling on N5).

  Such a step runs only in a scheduler run or an admin-UI run with a code (S8
  M7, ruling (b)). A chat that approves the run with its code, a chat's
  `/run`, MCP, a webhook, another node: the run is refused before it starts —
  no step of it runs — and the reply names the step and says where it can be
  run. Before, the run started, earlier steps ran, and it failed at the
  privileged step.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  import Ecto.Query, only: [from: 2]

  alias AlexClaw.Auth.{Challenge, CodeAttempts, TOTP}
  alias AlexClaw.{ControlPlane, Dispatcher, Message, RecordingGateway, Workflows}
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Workflows.WorkflowRun
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)
    RecordingGateway.install()
    AlexClaw.Config.set("shell.enabled", "true", type: "boolean", category: "shell")

    {:ok, %{secret: secret}} = TOTP.setup()

    :ok =
      TOTP.confirm_setup(NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30))

    AlexClaw.Config.delete("auth.totp.last_used_at")

    chat = "privileged_#{System.unique_integer([:positive])}"
    AlexClaw.Config.set("telegram.chat_id", chat, type: "string", category: "telegram")

    %{secret: secret, chat: chat}
  end

  defp workflow(protected) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "up-front-#{System.unique_integer([:positive])}",
        enabled: true,
        metadata: %{"requires_2fa" => protected}
      })

    {:ok, _} =
      Workflows.add_step(wf, %{name: "Shell", skill: "shell", config: %{"command" => "uptime"}})

    wf
  end

  defp runs_of(wf) do
    AlexClaw.TaskDrain.drain()

    Repo.aggregate(
      from(r in WorkflowRun, where: r.workflow_id == ^wf.id),
      :count
    )
  end

  defp reply(chat, text) do
    Dispatcher.dispatch(%Message{
      text: text,
      chat_id: chat,
      from: "Test",
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: :test
    })

    RecordingGateway.sent() |> List.last()
  end

  test "a chat's code for it is refused up front, and the reply says why", ctx do
    wf = workflow(true)
    Challenge.create(ctx.chat, %{type: :run_workflow, workflow_id: wf.id})

    answer = reply(ctx.chat, NimbleTOTP.verification_code(ctx.secret))

    assert answer =~ "shell"
    assert answer =~ "admin UI"
    assert runs_of(wf) == 0
  end

  for protected <- [false, true] do
    test "a chat's /run of it is refused up front, and the reply says why (protected: #{protected})",
         ctx do
      wf = workflow(unquote(protected))

      answer = reply(ctx.chat, "/run #{wf.name}")

      assert answer =~ "shell"
      assert answer =~ "admin UI"
      refute Challenge.pending?(ctx.chat), "the chat was asked for a code it cannot give"
      assert runs_of(wf) == 0
    end
  end

  for {what, context} <- [
        {"MCP", quote(do: Context.mcp("probe"))},
        {"a webhook", quote(do: Context.webhook("github"))}
      ] do
    test "a start from #{what} is refused before any step runs" do
      wf = workflow(false)

      assert {:error, {:privileged_steps, ["shell"]}} =
               ControlPlane.perform(:run_workflow, %{workflow_id: wf.id}, unquote(context))

      assert runs_of(wf) == 0
    end
  end
end
