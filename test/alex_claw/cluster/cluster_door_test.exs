defmodule AlexClaw.Cluster.ClusterDoorTest do
  @moduledoc """
  The cluster goes through the one door too (reports/S5_INVENTORY.md §1.9,
  §5, §8 items 6 and 23; 0.4.0 S5c).

  - A node is REGISTERED in the admin UI (save_node, elevation). A BEAM node
    that merely connects — it only needs the cookie — is not registered by
    connecting, and its arrival is audited as unregistered.
  - Another node asking this one to run a workflow is an entry point of its
    own, `:cluster`: it may run unprotected workflows, and only from a
    registered node that the target workflow allows. A refusal happens
    BEFORE anything starts — no run row exists for a refused request (the
    `allowed_nodes` check used to run inside step 1, after the run row).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  import Ecto.Query

  alias AlexClaw.{Cluster, ControlPlane, Workflows}
  alias AlexClaw.ControlPlane.Context

  @stranger :"stranger@10.0.0.99"

  defp runs_of(wf) do
    Repo.aggregate(
      from(r in AlexClaw.Workflows.WorkflowRun, where: r.workflow_id == ^wf.id),
      :count
    )
  end

  defp audited(fragment) do
    Repo.all(from(e in AlexClaw.Auth.AuditEntry, where: like(e.reason, ^"%#{fragment}%")))
  end

  defp remote_workflow(allowed) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "remote-#{System.unique_integer([:positive])}",
        enabled: true
      })

    {:ok, _} =
      Workflows.add_step(wf, %{
        name: "Receive",
        skill: "receive_from_workflow",
        config: %{"allowed_nodes" => allowed}
      })

    wf
  end

  describe "registration" do
    test "a node that connects is not registered by connecting, and it is audited" do
      before = Cluster.list_nodes() |> length()

      # :net_kernel.monitor_nodes(true) delivers {:nodeup, node}, a 2-tuple.
      send(AlexClaw.Cluster.Manager, {:nodeup, @stranger})
      # Let the manager handle it.
      :sys.get_state(AlexClaw.Cluster.Manager)

      assert length(Cluster.list_nodes()) == before
      assert Enum.any?(audited(to_string(@stranger)), &(&1.decision == "deny"))
    end

    test "a node is registered through the door, from the admin UI with the elevation" do
      assert Map.fetch!(ControlPlane.catalogue(), :save_node) == %{admin_ui: :elevation}
    end
  end

  describe "a run requested by another node" do
    test "the catalogue lets the cluster run unprotected workflows, and nothing else" do
      catalogue = ControlPlane.catalogue()

      assert catalogue[:run_workflow][:cluster] == :none

      others =
        for {action, entries} <- catalogue,
            action != :run_workflow,
            Map.has_key?(entries, :cluster),
            do: action

      assert others == [], "the cluster may also ask for: #{inspect(others)}"
    end

    test "from an unregistered node: refused before any run starts, and audited" do
      wf = remote_workflow([to_string(@stranger)])

      assert {:error, :node_not_registered} =
               ControlPlane.perform(
                 :run_workflow,
                 %{workflow_id: wf.id, input: %{}},
                 Context.cluster(@stranger)
               )

      assert runs_of(wf) == 0

      assert Enum.any?(
               audited("run_workflow"),
               &(&1.decision == "deny" and &1.reason =~ "cluster")
             )
    end

    test "from a registered node the workflow does not allow: refused before any run starts" do
      {:ok, _} = Cluster.create_node(%{name: "other@10.0.0.2", host: "10.0.0.2"})
      wf = remote_workflow(["someone-else@10.0.0.3"])

      assert {:error, :node_not_allowed} =
               ControlPlane.perform(
                 :run_workflow,
                 %{workflow_id: wf.id, input: %{}},
                 Context.cluster(:"other@10.0.0.2")
               )

      assert runs_of(wf) == 0
    end

    test "a protected workflow is refused to the cluster, whoever asks" do
      {:ok, _} = Cluster.create_node(%{name: "other@10.0.0.2", host: "10.0.0.2"})

      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "remote-protected-#{System.unique_integer([:positive])}",
          enabled: true,
          metadata: %{"requires_2fa" => true}
        })

      assert {:error, _} =
               ControlPlane.perform(
                 :run_workflow,
                 %{workflow_id: wf.id, input: %{}},
                 Context.cluster(:"other@10.0.0.2")
               )

      assert runs_of(wf) == 0
    end
  end
end
