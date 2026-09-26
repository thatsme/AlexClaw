defmodule AlexClaw.Config.UpgradeEverySealedValueTest do
  @moduledoc """
  The upgrade leaves no 0.3.x ciphertext in a step's config, whatever the
  step's skill, and writes no credential back in the clear (S8 M1).

  0.3.x sealed every key any skill declared secret, in every step: a step of
  one skill could hold another's `bot_token` or `headers`, sealed. Such a
  value is not one of its skill's credentials, so it is not moved as one: it
  is parked in OpenBao, bound to nothing it can be sent to, its field is
  emptied, and it is named in the log to be declared or deleted — never left
  sealed (unreadable once 0.3.x support goes), never lost.

  A header named like a password, a session or a cookie is a credential too:
  it moves to OpenBao, where 0.3.x kept it sealed; it is not written back in
  plain text.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  import ExUnit.CaptureLog

  alias AlexClaw.Config.SecretUpgrade
  alias AlexClaw.{Secrets, Workflows}
  alias AlexClawTest.Legacy

  setup do
    Legacy.clear_declared_secrets()
    {:ok, workflow} = Workflows.create_workflow(%{name: "sealed-#{System.unique_integer()}"})
    %{workflow: workflow}
  end

  defp config(id) do
    %{rows: [[config]]} = Repo.query!("SELECT config FROM workflow_steps WHERE id = $1", [id])
    config
  end

  test "another skill's sealed key is parked, not left sealed", %{workflow: workflow} do
    id =
      Legacy.insert_step(workflow.id, "rss_collector", %{
        "feeds" => ["https://example.com/feed"],
        "bot_token" => "123:not-this-skills-token"
      })

    log = capture_log(fn -> assert {:ok, _report} = SecretUpgrade.run() end)

    refute inspect(config(id)) =~ "enc:"
    refute inspect(config(id)) =~ "123:not-this-skills-token"

    [parked] = Regex.run(~r/parked_step_[a-z0-9_]+/, log)
    assert Secrets.value_matches?(parked, "123:not-this-skills-token")
    assert %{binding: ["inbound:carried_over"]} = Secrets.get(parked)
  end

  test "a password header moves as a credential, not back in the clear", %{workflow: workflow} do
    id =
      Legacy.insert_step(workflow.id, "api_request", %{
        "url" => "https://api.example.com/x",
        "headers" => %{"X-Password" => "hunter2-legacy", "Accept" => "application/json"}
      })

    assert {:ok, _report} = SecretUpgrade.run()

    headers = config(id)["headers"]
    assert %{"secret" => name} = headers["X-Password"]
    assert Secrets.value_matches?(name, "hunter2-legacy")
    assert %{"secret" => accept} = headers["Accept"]
    assert Secrets.value_matches?(accept, "application/json")
  end
end
