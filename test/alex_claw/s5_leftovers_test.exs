defmodule AlexClaw.S5LeftoversTest do
  @moduledoc """
  The inventory's "other findings" that belong to S5 (reports/S5_INVENTORY.md
  §2.2, §3, §6, §8 "Other findings"; 0.4.0 S5c).

  - Deleting a secret setting's ROW (the Config page's delete, `Config.remove/1`)
    left its value in OpenBao and its catalogue entry: removing a secret key
    removes the secret.
  - Sign out everywhere closed the sessions but left their elevations alive
    (in ETS, until expiry): it revokes them too.
  - A web_automation workflow step could RECORD (`action: "record"`) — and
    recording is authoring, admin UI only (§4.3): a step that records is
    refused at save, and at run time for one saved before.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.Elevation
  alias AlexClaw.{Config, ControlPlane, Secrets, Workflows}
  alias AlexClaw.ControlPlane.Context

  describe "removing a secret setting's row" do
    @describetag :vault

    test "removes its value from OpenBao and its catalogue entry" do
      {:ok, _} =
        Config.set("telegram.bot_token", "123-remove-me", type: "string", category: "telegram")

      assert Secrets.get("setting_telegram_bot_token")

      Config.remove("telegram.bot_token")

      assert is_nil(Secrets.get("setting_telegram_bot_token"))

      assert {:error, :not_found} =
               AlexClaw.Vault.read("alexclaw/secrets/setting_telegram_bot_token")
    end
  end

  describe "sign out everywhere" do
    test "revokes the elevations of the sessions it closes" do
      mine = Elevation.new_sid()
      other = Elevation.new_sid()
      :ok = AlexClaw.Auth.Sessions.open(mine, System.system_time(:second))
      :ok = AlexClaw.Auth.Sessions.open(other, System.system_time(:second))
      {:ok, _} = Elevation.grant(mine)
      {:ok, _} = Elevation.grant(other)

      assert {:ok, _} = ControlPlane.perform(:sign_out_everywhere, %{}, Context.admin_ui(mine))

      refute Elevation.elevated?(other), "a closed session kept its elevation"
    end
  end

  describe "a web_automation step that records" do
    setup do
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")

      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "records-#{System.unique_integer([:positive])}",
          enabled: true
        })

      %{wf: wf}
    end

    test "is refused at save: recording is authoring, admin UI only", %{wf: wf} do
      assert {:error, changeset} =
               Workflows.add_step(wf, %{
                 name: "Record",
                 skill: "web_automation",
                 config: %{"action" => "record", "url" => "https://example.com"}
               })

      assert inspect(changeset.errors) =~ ~r/record|admin UI/i
    end

    test "one saved before is refused at run time, and records nothing", %{wf: wf} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

      Repo.insert!(%AlexClaw.Workflows.WorkflowStep{
        workflow_id: wf.id,
        name: "Record",
        skill: "web_automation",
        position: 1,
        config: %{"action" => "record", "url" => "https://example.com"}
      })

      assert {:error, run} = AlexClaw.Workflows.Executor.run(wf.id)
      assert run.status == "failed"
      assert inspect(run) =~ ~r/record/i
    end
  end
end
