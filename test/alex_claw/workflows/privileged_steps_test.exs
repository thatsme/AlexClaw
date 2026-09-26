defmodule AlexClaw.Workflows.PrivilegedStepsTest do
  @moduledoc """
  A privileged step runs only when the scheduler starts the run, or when the
  admin UI starts it with a code (S8 M7; ruling S9: option (b)).

  Privileged steps are the skills that reach the host, the filesystem or the
  network on their own (`AlexClaw.Skills.Invoke.privileged_skills/0`: shell,
  coder, db_backup, web_automation). A run started from MCP, a webhook, a chat
  or another node — or from the admin UI without a code — fails at such a
  step, naming it, and the skill never runs. Whether a run may run them is
  decided by the control plane from the entry point, never taken from the
  caller's params. The admin UI asks for a code to run a workflow that has a
  privileged step, as it does for a protected one.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{Challenge, CodeAttempts, Elevation, TOTP}
  alias AlexClaw.{ControlPlane, Workflows}
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Workflows.{Launch, SchedulerSync, WorkflowRun}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    AlexClaw.Config.set("shell.enabled", "true", type: "boolean", category: "shell")

    {:ok, wf} =
      Workflows.create_workflow(%{name: "privileged #{System.unique_integer()}", enabled: true})

    {:ok, _step} =
      Workflows.add_step(wf, %{name: "Shell", skill: "shell", config: %{"command" => "uptime"}})

    %{wf: wf}
  end

  defp error_of({_status, %WorkflowRun{id: id}}), do: inspect(Repo.get!(WorkflowRun, id).error)
  defp error_of(other), do: inspect(other)

  defp refused_as_privileged?(result), do: error_of(result) =~ "privileged_step"

  for {what, context} <- [
        {"MCP", quote(do: Context.mcp("probe"))},
        {"a chat", quote(do: Context.gateway("42"))},
        {"a webhook", quote(do: Context.webhook("github"))},
        {"the admin UI without a code", quote(do: Context.admin_ui(nil))}
      ] do
    test "a run started from #{what} fails at the privileged step", %{wf: wf} do
      result =
        ControlPlane.perform(
          :run_workflow,
          %{workflow_id: wf.id, wait: true},
          unquote(context)
        )

      assert refused_as_privileged?(result), error_of(result)
    end
  end

  test "a caller cannot claim the privilege in its params", %{wf: wf} do
    result =
      ControlPlane.perform(
        :run_workflow,
        %{workflow_id: wf.id, wait: true, privileged: true},
        Context.mcp("probe")
      )

    assert refused_as_privileged?(result), error_of(result)
  end

  test "a run the scheduler starts may run it", %{wf: wf} do
    # What the scheduler's job for this workflow runs.
    {module, fun, args} = SchedulerSync.task_for(wf)
    result = apply(module, fun, args)

    refute refused_as_privileged?(result), error_of(result)
  end

  test "the admin UI asks for a code to run a workflow with a privileged step", %{wf: wf} do
    {:ok, workflow} = Workflows.get_workflow(wf.id)
    assert Launch.needs_code?(workflow)
  end

  test "a run the admin UI starts with a code may run it", %{wf: wf} do
    secret = NimbleTOTP.secret()

    AlexClaw.Config.set("auth.totp.secret", Base.encode32(secret, padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    AlexClaw.Config.delete("auth.totp.last_used_at")
    sid = Elevation.new_sid()
    context = Context.admin_ui(sid, NimbleTOTP.verification_code(secret))

    assert {:ok, {:started, _}} =
             ControlPlane.perform(:run_protected_workflow, %{workflow_id: wf.id}, context)

    run = await_run(wf.id)
    refute inspect(run.error) =~ "privileged_step", inspect(run.error)
  end

  # A chat can approve a protected run with its code; that still does not
  # make the run privileged, and neither does the caller saying so.
  test "a run a chat approves with a code still fails at the privileged step", %{wf: wf} do
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)
    {:ok, %{secret: secret}} = TOTP.setup()

    :ok =
      TOTP.confirm_setup(NimbleTOTP.verification_code(secret, time: System.os_time(:second) - 30))

    chat = "privileged-chat-#{System.unique_integer([:positive])}"
    Challenge.create(chat, %{type: :run_workflow, workflow_id: wf.id})
    context = Context.gateway(chat, NimbleTOTP.verification_code(secret))

    assert {:ok, {:started, _}} =
             ControlPlane.perform(
               :run_protected_workflow,
               %{workflow_id: wf.id, privileged: true},
               context
             )

    run = await_run(wf.id)
    assert inspect(run.error) =~ "privileged_step", inspect(run.error)
  end

  defp await_run(workflow_id, tries \\ 100) do
    AlexClaw.TaskDrain.drain()

    case Repo.one(
           from(r in WorkflowRun, where: r.workflow_id == ^workflow_id and r.status != "running")
         ) do
      nil when tries > 0 ->
        Process.sleep(50)
        await_run(workflow_id, tries - 1)

      run ->
        run
    end
  end
end
