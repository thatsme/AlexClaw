defmodule AlexClaw.Workflows.RequiresTwoFactorTest do
  @moduledoc """
  "Requires 2FA" means a person approves each run (reports/
  WORKFLOW_LIFECYCLE_REVIEW.md, cause 4; decided 2026-09-23).

  The flag was enforced by the UI's Run button, the Scheduler page and
  Telegram `/run` — and not by schedules, MCP, the cluster trigger, the
  GitHub webhook or SkillAPI. A protection that guards two doors out of seven
  looks like protection and is not.

  The rule, in one place:
  - a workflow that requires 2FA cannot have a schedule — refused at save,
    whichever of the two is set second;
  - the executor refuses to run such a workflow unless the run carries an
    approval: `AlexClaw.Auth.RunApproval.grant/1` returns one only for a
    workflow id, after the caller has verified a code; it is valid for that
    workflow, once, for a short time. Every entry point that cannot hold one
    — schedules, MCP, cluster, webhook, SkillAPI — is refused;
  - "set" is one stored boolean: the form's values are normalised at save,
    so every reader agrees and a ticked box can never read as unset.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.RunApproval
  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  defp workflow(attrs) do
    base = %{name: "2FA #{System.unique_integer([:positive])}", enabled: true}
    Workflows.create_workflow(Map.merge(base, attrs))
  end

  defp protected do
    {:ok, wf} = workflow(%{metadata: %{"requires_2fa" => true}})
    wf
  end

  describe "a protected workflow cannot be scheduled" do
    test "creating one with both is refused" do
      assert {:error, changeset} =
               workflow(%{metadata: %{"requires_2fa" => true}, schedule: "0 6 * * *"})

      assert changeset.errors[:schedule]
    end

    test "adding a schedule to a protected workflow is refused" do
      wf = protected()
      assert {:error, changeset} = Workflows.update_workflow(wf, %{schedule: "0 6 * * *"})
      assert changeset.errors[:schedule]
    end

    test "protecting a scheduled workflow is refused" do
      {:ok, wf} = workflow(%{schedule: "0 6 * * *"})

      assert {:error, changeset} =
               Workflows.update_workflow(wf, %{metadata: %{"requires_2fa" => true}})

      assert changeset.errors[:schedule]
    end
  end

  describe "the executor refuses a protected run without an approval" do
    test "every entry point that cannot hold one" do
      wf = protected()

      assert {:error, :approval_required} = Executor.run(wf.id)
      assert {:error, :approval_required} = Executor.run_with_initial_input(wf.id, "x")
      assert {:error, :approval_required} = Executor.run_remote_trigger(wf.id, "x", %{})
      assert Workflows.list_runs(wf.id) == [], "a refused run left a run row"
    end

    test "an unprotected workflow runs as before" do
      {:ok, wf} = workflow(%{})
      assert {:ok, _run} = Executor.run(wf.id)
    end
  end

  describe "an approval" do
    test "lets exactly that workflow run, once" do
      wf = protected()
      approval = RunApproval.grant(wf.id)

      assert {:ok, _run} = Executor.run(wf.id, approval: approval)
      assert {:error, :approval_required} = Executor.run(wf.id, approval: approval)
    end

    test "for another workflow is refused" do
      wf = protected()
      other = protected()
      approval = RunApproval.grant(other.id)

      assert {:error, :approval_required} = Executor.run(wf.id, approval: approval)
    end

    test "cannot be forged" do
      wf = protected()

      for fake <- [true, "approved", %{workflow_id: wf.id}, make_ref()] do
        assert {:error, :approval_required} = Executor.run(wf.id, approval: fake)
      end
    end

    test "expires" do
      wf = protected()
      approval = RunApproval.grant(wf.id, ttl_ms: 50)
      Process.sleep(100)

      assert {:error, :approval_required} = Executor.run(wf.id, approval: approval)
    end
  end

  describe "one reading of the flag" do
    # Normalised at save, so the stored value is always a boolean and every
    # reader agrees. The unsafe direction — a value the form sends being
    # read as "not set" — must be impossible.
    test "what the form sends for a ticked box is stored as true, and protects" do
      for value <- [true, "true", "on"] do
        {:ok, wf} = workflow(%{metadata: %{"requires_2fa" => value}})

        assert wf.metadata["requires_2fa"] == true,
               "#{inspect(value)} was stored as #{inspect(wf.metadata["requires_2fa"])}"

        assert {:error, :approval_required} = Executor.run(wf.id)
      end
    end

    test "an unticked box is stored as false, and does not protect" do
      for value <- [false, "false", nil] do
        {:ok, wf} = workflow(%{metadata: %{"requires_2fa" => value}})

        assert wf.metadata["requires_2fa"] in [false, nil]
        assert {:ok, _run} = Executor.run(wf.id)
      end
    end
  end
end
