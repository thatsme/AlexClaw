defmodule AlexClaw.Workflows.RunSnapshotTest do
  @moduledoc """
  A run keeps the definition it ran (reports/WORKFLOW_LIFECYCLE_REVIEW.md,
  cause 2; 0.3.55).

  A run stored only its results, keyed by position; its history was read
  against the workflow as it is NOW. Rename, reorder or delete a step, and an
  old run's history described steps it never ran.

  Now a run records `definition` when it starts: for each step, its position,
  name, skill, config, routes and input_from — as they were. Editing the
  workflow afterwards leaves it untouched. Secret config values (the keys a
  skill declares with `secret_config_keys/0`) are not copied: the snapshot
  holds a placeholder, so a run's history never becomes a second place a
  token is stored.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.Executor
  alias Ecto.Adapters.SQL.Sandbox

  @placeholder "<secret>"

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    bypass = Bypass.open()
    Bypass.stub(bypass, "GET", "/ok", &Plug.Conn.resp(&1, 200, "ok"))

    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Snapshot #{System.unique_integer([:positive])}",
        enabled: true
      })

    {:ok, fetch} =
      Workflows.add_step(wf, %{
        name: "Fetch",
        skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/ok"},
        routes: [%{"branch" => "on_2xx", "goto" => "end"}]
      })

    %{wf: wf, fetch: fetch}
  end

  test "a run records each step as it was when it ran", %{wf: wf} do
    assert {:ok, run} = Executor.run(wf.id)

    assert [step] = run.definition["steps"]
    assert step["position"] == 1
    assert step["name"] == "Fetch"
    assert step["skill"] == "api_request"
    assert step["config"]["url"] =~ "/ok"
    assert step["routes"] == [%{"branch" => "on_2xx", "goto" => "end"}]
  end

  test "editing the workflow afterwards does not change an old run's definition",
       %{wf: wf, fetch: fetch} do
    {:ok, run} = Executor.run(wf.id)

    {:ok, _} = Workflows.update_step(fetch, %{name: "Renamed"})

    {:ok, _} =
      Workflows.add_step(wf, %{
        name: "Added later",
        skill: "api_request",
        config: %{"url" => "https://example.com"}
      })

    stored = Workflows.get_run!(run.id)
    assert [%{"name" => "Fetch"}] = stored.definition["steps"]
  end

  test "secret config values are not copied into the snapshot", %{wf: wf} do
    # No TelegramStub: this step carries its own bot_token and chat_id, which
    # is what makes it available. Configuring the main Telegram would only add
    # the executor's fire-and-forget "workflow started" notice, racing the
    # end of the test.
    {:ok, _} =
      Workflows.add_step(wf, %{
        name: "Notify",
        skill: "telegram_notify",
        config: %{"bot_token" => "123:super-secret-token", "chat_id" => "42"}
      })

    {:ok, run} = Executor.run(wf.id)
    stored = Workflows.get_run!(run.id)

    notify = Enum.find(stored.definition["steps"], &(&1["name"] == "Notify"))
    assert notify["config"]["bot_token"] == @placeholder
    assert notify["config"]["chat_id"] == "42"
    refute inspect(stored.definition) =~ "super-secret-token"
  end
end
