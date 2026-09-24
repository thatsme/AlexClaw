defmodule AlexClaw.Workflows.BranchKindsTest do
  @moduledoc """
  A skill says which of its branches mean failure (0.3.51).

  `api_request` answers a 500 with `{:ok, body, :on_5xx}`, `web_fetch` a 404
  with `:on_not_found`, `shell` a failed command with `:on_error` — routable
  branches that workflows are built on. But the executor could not tell them
  from a success: unrouted, `on_5xx` went to the next step with the error
  body as its input, and the run completed.

  Each skill now declares:
  - `error_routes/0` — branches that mean the step failed (default
    `[:on_error]`);
  - `empty_routes/0` — branches that mean "nothing to do" (default
    `[:on_empty]`).
  `AlexClaw.Skill.error_routes/1` and `empty_routes/1` apply the defaults.

  The executor treats an unrouted error route exactly like `{:error, _}`: the
  run fails, naming the step and the branch. A routed one ends the run
  `recovered`. An unrouted empty route ends it `completed`.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skill
  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor
  alias Ecto.Adapters.SQL.Sandbox

  defmodule NoDeclarations do
    @moduledoc false
    def routes, do: [:on_success, :on_error, :on_empty]
  end

  # Every compiled skill module, found by what it exports — a new skill is
  # covered without anyone adding it here.
  defp skill_modules do
    for module <- Application.spec(:alex_claw, :modules),
        String.starts_with?(inspect(module), "AlexClaw.Skills."),
        Code.ensure_loaded?(module),
        function_exported?(module, :run, 1),
        function_exported?(module, :routes, 0),
        do: module
  end

  describe "the declarations" do
    test "the scan finds the skills (no vacuous pass)" do
      assert AlexClaw.Skills.ApiRequest in skill_modules()
      assert length(skill_modules()) > 15
    end

    test "every skill's error and empty routes are among its routes, and disjoint" do
      for skill <- skill_modules() do
        routes = MapSet.new(skill.routes())
        errors = MapSet.new(Skill.error_routes(skill))
        empties = MapSet.new(Skill.empty_routes(skill))

        assert MapSet.subset?(errors, MapSet.put(routes, :on_error)),
               "#{inspect(skill)} declares error routes it never returns: " <>
                 inspect(MapSet.difference(errors, routes) |> MapSet.delete(:on_error))

        assert MapSet.disjoint?(errors, empties),
               "#{inspect(skill)}: a route is both error and empty"
      end
    end

    # A route whose name says failure is declared as one. The names are the
    # convention the codebase already follows; a skill that means something
    # else by them says so by not using them.
    test "routes named for a failure are declared as error routes" do
      failure_names = [:on_error, :on_timeout, :on_not_found, :on_4xx, :on_5xx]

      for skill <- skill_modules(), route <- skill.routes(), route in failure_names do
        assert route in Skill.error_routes(skill),
               "#{inspect(skill)} returns #{route} but does not declare it an error route"
      end
    end

    test "routes named for nothing found are declared as empty routes" do
      for skill <- skill_modules(),
          route <- skill.routes(),
          route in [:on_empty, :on_no_results] do
        assert route in Skill.empty_routes(skill),
               "#{inspect(skill)} returns #{route} but does not declare it an empty route"
      end
    end

    test "the defaults apply to a skill that declares nothing" do
      assert Skill.error_routes(AlexClaw.Workflows.BranchKindsTest.NoDeclarations) == [:on_error]
      assert Skill.empty_routes(AlexClaw.Workflows.BranchKindsTest.NoDeclarations) == [:on_empty]
    end
  end

  describe "the executor" do
    setup do
      Sandbox.mode(AlexClaw.Repo, {:shared, self()})
      bypass = Bypass.open()
      Bypass.stub(bypass, "GET", "/boom", &Plug.Conn.resp(&1, 500, "boom"))
      Bypass.stub(bypass, "GET", "/ok", &Plug.Conn.resp(&1, 200, "ok"))

      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "Kinds #{System.unique_integer([:positive])}",
          enabled: true
        })

      %{wf: wf, base: "http://localhost:#{bypass.port}"}
    end

    test "an unrouted error route fails the run, naming the step and the branch",
         %{wf: wf, base: base} do
      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Fetch",
          skill: "api_request",
          config: %{"url" => base <> "/boom"}
        })

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Never",
          skill: "api_request",
          config: %{"url" => base <> "/ok"}
        })

      assert {:error, run} = Executor.run(wf.id)
      assert run.status == "failed"
      assert run.error =~ "Fetch"
      assert run.error =~ "on_5xx"
      refute Map.has_key?(run.step_results, "2"), "the error body went on to the next step"
    end

    test "a routed error route ends the run recovered", %{wf: wf, base: base} do
      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Fetch",
          skill: "api_request",
          config: %{"url" => base <> "/boom"},
          routes: [%{"branch" => "on_5xx", "goto" => 2}]
        })

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "Handle",
          skill: "api_request",
          config: %{"url" => base <> "/ok"}
        })

      assert {:ok, run} = Executor.run(wf.id)
      assert run.status == "recovered"
    end
  end
end
