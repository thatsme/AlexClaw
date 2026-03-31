defmodule AlexClaw.WorkflowsExportImportTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows
  alias AlexClaw.Resources

  defp create_workflow(attrs \\ %{}) do
    default = %{name: "Test Workflow #{System.unique_integer([:positive])}", enabled: true}
    {:ok, wf} = Workflows.create_workflow(Map.merge(default, attrs))
    wf
  end

  defp create_resource(attrs \\ %{}) do
    default = %{name: "Resource #{System.unique_integer([:positive])}", type: "rss_feed", url: "https://example.com/feed"}
    {:ok, res} = Resources.create_resource(Map.merge(default, attrs))
    res
  end

  defp build_full_workflow do
    wf = create_workflow(%{name: "Full Export Test", description: "desc", schedule: "0 7 * * *", default_provider: "groq"})

    {:ok, _s1} = Workflows.add_step(wf, %{
      name: "Fetch", skill: "rss_collector", llm_tier: "light",
      config: %{"timeout" => 30}, routes: [%{"branch" => "on_items", "goto" => 2}]
    })

    {:ok, _s2} = Workflows.add_step(wf, %{
      name: "Transform", skill: "llm_transform", llm_tier: "medium",
      prompt_template: "Summarize: {{input}}", input_from: 1
    })

    res = create_resource(%{name: "Tech Feed"})
    {:ok, _} = Workflows.assign_resource(wf, res.id, "input")

    {:ok, wf} = Workflows.get_workflow(wf.id)
    {wf, res}
  end

  # --- export_workflow/1 ---

  describe "export_workflow/1" do
    test "serializes workflow metadata" do
      {wf, _res} = build_full_workflow()
      exported = Workflows.export_workflow(wf)

      assert exported["version"] == 1
      assert exported["workflow"]["name"] == "Full Export Test"
      assert exported["workflow"]["description"] == "desc"
      assert exported["workflow"]["schedule"] == "0 7 * * *"
      assert exported["workflow"]["default_provider"] == "groq"
    end

    test "serializes steps with all fields including routes and input_from" do
      {wf, _res} = build_full_workflow()
      exported = Workflows.export_workflow(wf)

      steps = exported["steps"]
      assert length(steps) == 2

      [s1, s2] = Enum.sort_by(steps, & &1["position"])
      assert s1["name"] == "Fetch"
      assert s1["skill"] == "rss_collector"
      assert s1["config"] == %{"timeout" => 30}
      assert s1["routes"] == [%{"branch" => "on_items", "goto" => 2}]
      assert s1["input_from"] == nil

      assert s2["name"] == "Transform"
      assert s2["input_from"] == 1
      assert s2["prompt_template"] == "Summarize: {{input}}"
    end

    test "serializes resource references by name" do
      {wf, _res} = build_full_workflow()
      exported = Workflows.export_workflow(wf)

      assert length(exported["resources"]) == 1
      [res_ref] = exported["resources"]
      assert res_ref["name"] == "Tech Feed"
      assert res_ref["type"] == "rss_feed"
      assert res_ref["role"] == "input"
    end

    test "does not include database IDs or timestamps" do
      {wf, _res} = build_full_workflow()
      exported = Workflows.export_workflow(wf)

      refute Map.has_key?(exported["workflow"], "id")
      refute Map.has_key?(exported["workflow"], "inserted_at")
      refute Map.has_key?(exported["workflow"], "updated_at")

      Enum.each(exported["steps"], fn step ->
        refute Map.has_key?(step, "id")
        refute Map.has_key?(step, "workflow_id")
      end)
    end

    test "workflow with no steps or resources exports cleanly" do
      wf = create_workflow(%{name: "Empty Workflow"})
      {:ok, wf} = Workflows.get_workflow(wf.id)
      exported = Workflows.export_workflow(wf)

      assert exported["steps"] == []
      assert exported["resources"] == []
      assert exported["workflow"]["name"] == "Empty Workflow"
    end
  end

  # --- import_workflow/1 ---

  describe "import_workflow/1" do
    test "round-trips through export and import" do
      {wf, _res} = build_full_workflow()
      exported = Workflows.export_workflow(wf)

      {:ok, imported, warnings} = Workflows.import_workflow(exported)

      assert imported.name == "Full Export Test (imported 1)"
      assert warnings == []

      {:ok, loaded} = Workflows.get_workflow(imported.id)
      assert length(loaded.steps) == 2

      [s1, s2] = Enum.sort_by(loaded.steps, & &1.position)
      assert s1.position == 1
      assert s1.routes == [%{"branch" => "on_items", "goto" => 2}]
      assert s2.position == 2
      assert s2.input_from == 1
    end

    test "preserves explicit step positions" do
      data = %{
        "version" => 1,
        "workflow" => %{"name" => "Position Test"},
        "steps" => [
          %{"position" => 5, "name" => "Step A", "skill" => "api_request"},
          %{"position" => 10, "name" => "Step B", "skill" => "llm_transform"}
        ],
        "resources" => []
      }

      {:ok, wf, []} = Workflows.import_workflow(data)
      {:ok, loaded} = Workflows.get_workflow(wf.id)
      positions = Enum.map(loaded.steps, & &1.position)
      assert 5 in positions
      assert 10 in positions
    end

    test "uses original name when no conflict" do
      data = %{
        "version" => 1,
        "workflow" => %{"name" => "Unique Name #{System.unique_integer([:positive])}"},
        "steps" => [],
        "resources" => []
      }

      {:ok, wf, []} = Workflows.import_workflow(data)
      assert wf.name == data["workflow"]["name"]
    end

    test "appends incrementing suffix on name conflict" do
      name = "Conflict Test #{System.unique_integer([:positive])}"
      create_workflow(%{name: name})

      data = %{
        "version" => 1,
        "workflow" => %{"name" => name},
        "steps" => [],
        "resources" => []
      }

      {:ok, wf1, []} = Workflows.import_workflow(data)
      assert wf1.name == "#{name} (imported 1)"

      {:ok, wf2, []} = Workflows.import_workflow(data)
      assert wf2.name == "#{name} (imported 2)"
    end

    test "reuses existing resource by name+url" do
      res = create_resource(%{name: "Existing Resource", url: "https://example.com/feed"})

      data = %{
        "version" => 1,
        "workflow" => %{"name" => "Reuse Resource Test #{System.unique_integer([:positive])}"},
        "steps" => [],
        "resources" => [
          %{"name" => "Existing Resource", "type" => "rss_feed", "url" => "https://example.com/feed", "role" => "input"}
        ]
      }

      {:ok, wf, warnings} = Workflows.import_workflow(data)
      assert warnings == []

      {:ok, loaded} = Workflows.get_workflow(wf.id)
      assert length(loaded.workflow_resources) == 1
      assert hd(loaded.workflow_resources).resource_id == res.id
    end

    test "creates missing resources on import" do
      data = %{
        "version" => 1,
        "workflow" => %{"name" => "New Resource Test #{System.unique_integer([:positive])}"},
        "steps" => [],
        "resources" => [
          %{"name" => "Brand New Feed", "type" => "rss_feed", "url" => "https://new.example.com/rss",
            "tags" => ["finance"], "enabled" => true, "role" => "input"}
        ]
      }

      {:ok, wf, warnings} = Workflows.import_workflow(data)
      assert length(warnings) == 1
      assert hd(warnings) =~ "created"

      {:ok, loaded} = Workflows.get_workflow(wf.id)
      assert length(loaded.workflow_resources) == 1

      created = AlexClaw.Repo.get!(AlexClaw.Resources.Resource, hd(loaded.workflow_resources).resource_id)
      assert created.name == "Brand New Feed"
      assert created.url == "https://new.example.com/rss"
      assert created.tags == ["finance"]
    end

    # --- Structural validation ---

    test "rejects non-map input" do
      assert {:error, msg} = Workflows.import_workflow("not a map")
      assert msg =~ "expected a JSON object"
    end

    test "rejects missing version" do
      assert {:error, msg} = Workflows.import_workflow(%{"workflow" => %{"name" => "X"}, "steps" => []})
      assert msg =~ "version"
    end

    test "rejects wrong version" do
      data = %{"version" => 99, "workflow" => %{"name" => "X"}, "steps" => []}
      assert {:error, msg} = Workflows.import_workflow(data)
      assert msg =~ "version"
    end

    test "rejects missing workflow field" do
      assert {:error, msg} = Workflows.import_workflow(%{"version" => 1, "steps" => []})
      assert msg =~ "workflow"
    end

    test "rejects missing workflow name" do
      data = %{"version" => 1, "workflow" => %{}, "steps" => []}
      assert {:error, msg} = Workflows.import_workflow(data)
      assert msg =~ "name"
    end

    test "rejects empty workflow name" do
      data = %{"version" => 1, "workflow" => %{"name" => ""}, "steps" => []}
      assert {:error, msg} = Workflows.import_workflow(data)
      assert msg =~ "name"
    end

    test "rejects missing steps field" do
      data = %{"version" => 1, "workflow" => %{"name" => "X"}}
      assert {:error, msg} = Workflows.import_workflow(data)
      assert msg =~ "steps"
    end

    test "rejects nil input" do
      assert {:error, msg} = Workflows.import_workflow(nil)
      assert msg =~ "expected a JSON object"
    end

    # --- Adversarial: step validation ---

    test "fails on step missing required fields" do
      data = %{
        "version" => 1,
        "workflow" => %{"name" => "Bad Step #{System.unique_integer([:positive])}"},
        "steps" => [%{"position" => 1}],
        "resources" => []
      }

      assert {:error, msg} = Workflows.import_workflow(data)
      assert msg =~ "name" or msg =~ "skill"
    end

    # --- Adversarial: empty collections ---

    test "imports workflow with empty steps and resources" do
      data = %{
        "version" => 1,
        "workflow" => %{"name" => "Empty #{System.unique_integer([:positive])}"},
        "steps" => [],
        "resources" => []
      }

      {:ok, wf, []} = Workflows.import_workflow(data)
      {:ok, loaded} = Workflows.get_workflow(wf.id)
      assert loaded.steps == []
      assert loaded.workflow_resources == []
    end
  end

  # --- duplicate_workflow bug fix ---

  describe "duplicate_workflow/1 copies input_from and routes" do
    test "cloned steps preserve input_from and routes" do
      {wf, _res} = build_full_workflow()
      {:ok, cloned} = Workflows.duplicate_workflow(wf)
      {:ok, loaded} = Workflows.get_workflow(cloned.id)

      [s1, s2] = Enum.sort_by(loaded.steps, & &1.position)
      assert s1.routes == [%{"branch" => "on_items", "goto" => 2}]
      assert s2.input_from == 1
    end
  end
end
