defmodule AlexClaw.Config.UpgradeOddValuesTest do
  @moduledoc """
  A 0.3.x credential that is not text does not stop the upgrade (S8 M12).

  0.3.x stored whatever JSON a step's config held. A number or a boolean in a
  credential field is carried over as its text; a list or an object cannot be
  one credential, so its record is reported and left as it was. Either way
  the upgrade completes and the application starts.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Config.SecretUpgrade
  alias AlexClaw.{Secrets, Workflows}
  alias AlexClawTest.Legacy

  setup do
    Legacy.clear_declared_secrets()
    {:ok, workflow} = Workflows.create_workflow(%{name: "odd-#{System.unique_integer()}"})
    %{workflow: workflow}
  end

  defp config(id) do
    %{rows: [[config]]} = Repo.query!("SELECT config FROM workflow_steps WHERE id = $1", [id])
    config
  end

  test "a number is carried over as its text", %{workflow: workflow} do
    id =
      Legacy.insert_step(workflow.id, "api_request", %{
        "url" => "https://api.example.com/x",
        "headers" => %{"X-API-Key" => 12_345_678}
      })

    assert {:ok, report} = SecretUpgrade.run()
    assert "step #{id}" in report.records_moved

    assert %{"secret" => name} = config(id)["headers"]["X-API-Key"]
    assert Secrets.value_matches?(name, "12345678")
  end

  test "a list is reported, and its record left as it was", %{workflow: workflow} do
    id =
      Legacy.insert_step(workflow.id, "api_request", %{
        "url" => "https://api.example.com/x",
        "headers" => %{"X-API-Key" => ["one", "two"]}
      })

    before = config(id)

    assert {:ok, report} = SecretUpgrade.run()
    assert Enum.any?(report.failed, &match?({"step " <> _, _reason}, &1))
    assert config(id) == before
  end
end
