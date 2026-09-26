defmodule AlexClaw.Config.UpgradeCarriesExactlyTest do
  @moduledoc """
  The upgrade carries a 0.3.x value exactly as it was, whitespace included,
  and a value it cannot judge never fails a boot (S9 fix review, ruling on
  N4).

  A value entered in 0.4.0 with surrounding whitespace or a control
  character is refused at entry (S8 H8), because it could only fail where
  it is sent. A value 0.3.x already holds is not being entered: it was in
  use as it is, and changing or refusing it would lose it. The settings,
  step and resource moves, and the parked custom settings, all carry it
  byte for byte; the report names no failure for it.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Config.SecretUpgrade
  alias AlexClaw.{Secrets, Workflows}
  alias AlexClawTest.Legacy

  setup do
    Legacy.clear_declared_secrets()
    {:ok, workflow} = Workflows.create_workflow(%{name: "exact-#{System.unique_integer()}"})
    %{workflow: workflow}
  end

  test "a declared setting with a trailing newline is carried as it is" do
    Legacy.insert_setting("github.token", "ghp_legacy-token\n", encrypted: true)

    assert {:ok, report} = SecretUpgrade.run()
    assert report.failed == []
    assert Secrets.value_matches?("setting_github_token", "ghp_legacy-token\n")
  end

  test "a step's header with surrounding spaces is carried as it is", %{workflow: workflow} do
    id =
      Legacy.insert_step(workflow.id, "api_request", %{
        "url" => "https://api.example.com/x",
        "headers" => %{"X-API-Key" => " spaced-key "}
      })

    assert {:ok, report} = SecretUpgrade.run()
    assert "step #{id}" in report.records_moved

    %{rows: [[config]]} = Repo.query!("SELECT config FROM workflow_steps WHERE id = $1", [id])
    assert %{"secret" => name} = config["headers"]["X-API-Key"]
    assert Secrets.value_matches?(name, " spaced-key ")
  end

  test "a custom sensitive setting with a trailing newline is parked as it is" do
    Legacy.insert_setting("custom.webhook_token", "custom-value\n", encrypted: true)

    assert {:ok, report} = SecretUpgrade.run()
    assert report.failed == []

    %{value: "", key: "custom.webhook_token"} =
      Repo.get_by!(AlexClaw.Config.Setting, key: "custom.webhook_token")

    [name] = report.custom_moved |> Enum.map(fn {_key, name} -> name end)
    assert Secrets.value_matches?(name, "custom-value\n")
  end
end
