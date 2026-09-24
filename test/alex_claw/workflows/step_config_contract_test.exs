defmodule AlexClaw.Workflows.StepConfigContractTest do
  @moduledoc """
  A step is saved only if it can run (reports/WORKFLOW_LIFECYCLE_REVIEW.md,
  cause 3; 0.3.54).

  Step config was a free map: a misspelled key, a number where a URL belongs,
  a skill that does not exist or is not configured — all saved, all found out
  at run time, usually at 6 a.m. The same problem the recipe contract solved
  for web automation, one level up.

  The rule — no defaults, no guessing:
  - every skill declares its config fields: `config_schema/0` returns
    `%{"field" => %{type: t, required: boolean}}`, t in :string, :integer,
    :number, :boolean, :map, :list;
  - saving a step refuses: an unknown key, a value of the wrong type, a
    missing required field, a skill that does not exist, and a skill that is
    not available (not configured: `available?/0` false);
  - saving a workflow refuses a schedule that is not a valid cron expression;
  - a step saved before this release that breaks the contract fails its run
    at that step, naming the step and the field — it does not run on
    whatever it was given.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor
  alias Ecto.Adapters.SQL.Sandbox

  @types [:string, :integer, :number, :boolean, :map, :list]

  defp skill_modules do
    for module <- Application.spec(:alex_claw, :modules),
        String.starts_with?(inspect(module), "AlexClaw.Skills."),
        Code.ensure_loaded?(module),
        function_exported?(module, :run, 1),
        function_exported?(module, :routes, 0),
        do: module
  end

  defp workflow do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Contract #{System.unique_integer([:positive])}",
        enabled: true
      })

    wf
  end

  defp error_text(changeset), do: inspect(changeset.errors)

  describe "the declarations" do
    test "the scan finds the skills (no vacuous pass)" do
      assert length(skill_modules()) > 15
    end

    test "every skill declares its config fields, each with a known type" do
      for skill <- skill_modules() do
        assert function_exported?(skill, :config_schema, 0),
               "#{inspect(skill)} declares no config_schema/0"

        for {field, spec} <- skill.config_schema() do
          assert is_binary(field), "#{inspect(skill)}: field #{inspect(field)} is not a string"

          assert spec.type in @types,
                 "#{inspect(skill)}.#{field}: unknown type #{inspect(spec.type)}"

          assert is_boolean(spec.required),
                 "#{inspect(skill)}.#{field}: required is not a boolean"
        end
      end
    end

    # The scaffold is what the UI pre-fills; every key it offers must be one
    # the contract accepts, or the UI would offer a step it then refuses.
    test "every key a skill's scaffold offers is a declared field" do
      for skill <- skill_modules(), function_exported?(skill, :config_scaffold, 0) do
        scaffold = skill.config_scaffold()

        if is_map(scaffold) do
          undeclared = Map.keys(scaffold) -- Map.keys(skill.config_schema())

          assert undeclared == [],
                 "#{inspect(skill)} scaffolds undeclared keys: #{inspect(undeclared)}"
        end
      end
    end

    # Presets are offered the same way; each must be a config the contract
    # accepts as it stands (github's "Specific PR" had pr_number: "").
    test "every preset a skill offers passes its own contract" do
      for skill <- skill_modules(),
          function_exported?(skill, :config_presets, 0),
          {name, preset} <- skill.config_presets(),
          is_map(preset) do
        assert :ok = AlexClaw.Workflows.StepConfig.validate(skill, preset),
               "#{inspect(skill)} preset #{inspect(name)} breaks its contract"
      end
    end

    test "no skill declares a reserved key (leading underscore)" do
      for skill <- skill_modules(), field <- Map.keys(skill.config_schema()) do
        refute String.starts_with?(field, "_"),
               "#{inspect(skill)} declares #{field}: keys starting with _ are reserved for the runtime"
      end
    end
  end

  describe "saving a step" do
    setup do
      %{wf: workflow()}
    end

    test "a valid config is saved", %{wf: wf} do
      assert {:ok, _} =
               Workflows.add_step(wf, %{
                 name: "Fetch",
                 skill: "api_request",
                 config: %{"url" => "https://example.com"}
               })
    end

    test "an unknown key is refused, naming it", %{wf: wf} do
      assert {:error, changeset} =
               Workflows.add_step(wf, %{
                 name: "Fetch",
                 skill: "api_request",
                 config: %{"url" => "https://example.com", "urll" => "typo"}
               })

      assert error_text(changeset) =~ "urll"
    end

    test "a value of the wrong type is refused, naming the field", %{wf: wf} do
      assert {:error, changeset} =
               Workflows.add_step(wf, %{
                 name: "Fetch",
                 skill: "api_request",
                 config: %{"url" => 42}
               })

      assert error_text(changeset) =~ "url"
    end

    test "a missing required field is refused, naming it", %{wf: wf} do
      # api_request needs a url, or a path with an assigned resource: a rule
      # across fields, declared by the skill's validate_config/1.
      assert {:error, changeset} =
               Workflows.add_step(wf, %{name: "Fetch", skill: "api_request", config: %{}})

      assert error_text(changeset) =~ "url"
    end

    test "a key reserved for the runtime (leading underscore) cannot be saved", %{wf: wf} do
      assert {:error, changeset} =
               Workflows.add_step(wf, %{
                 name: "Fetch",
                 skill: "api_request",
                 config: %{"url" => "https://example.com", "_source_node" => "x@y"}
               })

      assert error_text(changeset) =~ "_source_node"
    end

    test "a skill that does not exist is refused", %{wf: wf} do
      assert {:error, changeset} =
               Workflows.add_step(wf, %{name: "Ghost", skill: "no_such_skill", config: %{}})

      assert changeset.errors[:skill]
    end

    test "a skill that is not configured is refused, and says so", %{wf: wf} do
      insert_setting("web_automator.enabled", "false", type: "boolean", category: "web_automator")

      assert {:error, changeset} =
               Workflows.add_step(wf, %{
                 name: "Browse",
                 skill: "web_automation",
                 config: %{"url" => "https://example.com", "steps" => []}
               })

      assert error_text(changeset) =~ ~r/not configured/i
    end

    test "updating a step is held to the same contract", %{wf: wf} do
      {:ok, step} =
        Workflows.add_step(wf, %{
          name: "Fetch",
          skill: "api_request",
          config: %{"url" => "https://example.com"}
        })

      assert {:error, changeset} =
               Workflows.update_step(step, %{
                 config: %{"url" => "https://example.com", "urll" => "x"}
               })

      assert error_text(changeset) =~ "urll"
    end
  end

  describe "saving a workflow" do
    test "a schedule that is not a cron expression is refused" do
      for bad <- ["every morning", "* * *", "61 * * * *", "0 6 * * 8"] do
        assert {:error, changeset} =
                 Workflows.create_workflow(%{
                   name: "Cron #{System.unique_integer([:positive])}",
                   schedule: bad
                 })

        assert changeset.errors[:schedule], "#{inspect(bad)} was accepted"
      end
    end

    test "a valid cron expression is accepted" do
      assert {:ok, _} =
               Workflows.create_workflow(%{
                 name: "Cron #{System.unique_integer([:positive])}",
                 schedule: "0 6 * * 1-5"
               })
    end
  end

  # Steps saved before this release are not checked retroactively at save
  # time; they are checked when they run.
  describe "a step saved before the contract" do
    setup do
      Sandbox.mode(AlexClaw.Repo, {:shared, self()})
      :ok
    end

    test "fails its run at that step, naming the field" do
      wf = workflow()

      {:ok, step} =
        Workflows.add_step(wf, %{
          name: "Fetch",
          skill: "api_request",
          config: %{"url" => "https://example.com"}
        })

      # Written the way a pre-0.3.54 row looks: past the changeset.
      AlexClaw.Repo.update_all(
        from(s in AlexClaw.Workflows.WorkflowStep, where: s.id == ^step.id),
        set: [config: %{"url" => 42}]
      )

      assert {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
      assert run.error =~ "Fetch"
      assert run.error =~ "url"
    end
  end
end
