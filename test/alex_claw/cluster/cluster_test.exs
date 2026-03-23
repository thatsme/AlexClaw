defmodule AlexClaw.ClusterTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Cluster
  alias AlexClaw.Cluster.ClusterNode

  defp create_node(attrs \\ %{}) do
    default = %{name: "alexclaw@node#{System.unique_integer([:positive])}.local", label: "test"}
    {:ok, node} = Cluster.create_node(Map.merge(default, attrs))
    node
  end

  describe "create_node/1" do
    test "creates a node with valid attrs" do
      assert {:ok, %ClusterNode{} = node} =
               Cluster.create_node(%{name: "alexclaw@test.local", label: "Test Node"})

      assert node.name == "alexclaw@test.local"
      assert node.label == "Test Node"
      assert node.status == "unknown"
    end

    test "rejects duplicate name" do
      create_node(%{name: "alexclaw@dup.local"})
      assert {:error, changeset} = Cluster.create_node(%{name: "alexclaw@dup.local"})
      assert errors_on(changeset).name != []
    end

    test "rejects missing name" do
      assert {:error, changeset} = Cluster.create_node(%{label: "No Name"})
      assert errors_on(changeset).name != []
    end
  end

  describe "list_nodes/0" do
    test "returns all nodes ordered by name" do
      create_node(%{name: "alexclaw@z.local"})
      create_node(%{name: "alexclaw@a.local"})

      nodes = Cluster.list_nodes()
      names = Enum.map(nodes, & &1.name)

      assert "alexclaw@a.local" in names
      assert "alexclaw@z.local" in names
      # Verify ordering
      a_idx = Enum.find_index(names, &(&1 == "alexclaw@a.local"))
      z_idx = Enum.find_index(names, &(&1 == "alexclaw@z.local"))
      assert a_idx < z_idx
    end
  end

  describe "get_node!/1" do
    test "returns node by id" do
      node = create_node()
      assert Cluster.get_node!(node.id).name == node.name
    end

    test "raises for missing id" do
      assert_raise Ecto.NoResultsError, fn -> Cluster.get_node!(999_999) end
    end
  end

  describe "get_by_name/1" do
    test "returns node by name" do
      node = create_node(%{name: "alexclaw@find.local"})
      assert Cluster.get_by_name("alexclaw@find.local").id == node.id
    end

    test "returns nil for unknown name" do
      assert is_nil(Cluster.get_by_name("alexclaw@nonexistent.local"))
    end
  end

  describe "update_node/2" do
    test "updates status and last_seen_at" do
      node = create_node()
      now = DateTime.utc_now()

      assert {:ok, updated} =
               Cluster.update_node(node, %{status: "connected", last_seen_at: now})

      assert updated.status == "connected"
      assert updated.last_seen_at
    end
  end

  describe "delete_node/1" do
    test "removes node from database" do
      node = create_node(%{name: "alexclaw@delete.local"})
      assert {:ok, _} = Cluster.delete_node(node)
      assert is_nil(Cluster.get_by_name("alexclaw@delete.local"))
    end
  end

  describe "self_name/0" do
    test "returns a string" do
      assert is_binary(Cluster.self_name())
    end
  end

  describe "node_ping/1" do
    test "returns :pang for unknown node" do
      assert :pang = Cluster.node_ping("nonexistent@nowhere.local")
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
