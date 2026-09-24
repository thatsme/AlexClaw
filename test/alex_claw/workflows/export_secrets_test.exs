defmodule AlexClaw.Workflows.ExportSecretsTest do
  @moduledoc """
  A shared workflow file carries no credential. Export Workflow writes a
  placeholder for every config key a skill declares secret; an import leaves
  those keys empty and marks the step as needing secrets, until they are
  filled in again.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows

  setup do
    # 0.3.54: a telegram_notify step is saved only when Telegram is configured.
    insert_setting("telegram.enabled", "true", type: "boolean", category: "telegram")
    insert_setting("telegram.bot_token", "test-token", type: "string", category: "telegram")
    :ok
  end

  @placeholder "<secret not exported>"

  defp workflow_with_secrets do
    {:ok, wf} =
      Workflows.create_workflow(%{name: "secrets-#{System.unique_integer([:positive])}"})

    {:ok, tg} =
      Workflows.add_step(wf, %{
        name: "tg",
        skill: "telegram_notify",
        config: %{"bot_token" => "123:bot-secret", "chat_id" => "42"}
      })

    {:ok, api} =
      Workflows.add_step(wf, %{
        name: "api",
        skill: "api_request",
        config: %{
          "url" => "https://example.com",
          "headers" => %{"authorization" => "Bearer api-secret", "accept" => "text/plain"}
        }
      })

    {Workflows.get_workflow!(wf.id), tg, api}
  end

  defp step(exported, name), do: Enum.find(exported["steps"], &(&1["name"] == name))

  defp import!(exported) do
    {:ok, workflow, _warnings} = Workflows.import_workflow(exported)
    Workflows.get_workflow!(workflow.id)
  end

  describe "export" do
    test "the file contains no secret value, only placeholders" do
      {wf, _tg, _api} = workflow_with_secrets()
      exported = Workflows.export_workflow(wf)
      text = Jason.encode!(exported)

      for secret <- ["123:bot-secret", "api-secret", "text/plain"], do: refute(text =~ secret)

      assert step(exported, "tg")["config"] == %{"bot_token" => @placeholder, "chat_id" => "42"}

      assert step(exported, "api")["config"]["headers"] ==
               %{"authorization" => @placeholder, "accept" => @placeholder},
             "header names stay, so the importer knows what to fill in"

      assert step(exported, "api")["config"]["url"] == "https://example.com"
    end

    test "a secret that is empty stays empty" do
      {:ok, wf} = Workflows.create_workflow(%{name: "empty-secret"})

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "tg",
          skill: "telegram_notify",
          config: %{"bot_token" => ""}
        })

      exported = Workflows.export_workflow(Workflows.get_workflow!(wf.id))
      assert step(exported, "tg")["config"]["bot_token"] == ""
    end
  end

  describe "import" do
    test "leaves the secrets empty and flags each step that needs them" do
      {wf, _tg, _api} = workflow_with_secrets()
      imported = wf |> Workflows.export_workflow() |> import!()

      tg = Enum.find(imported.steps, &(&1.name == "tg"))
      api = Enum.find(imported.steps, &(&1.name == "api"))

      assert tg.config == %{"bot_token" => "", "chat_id" => "42"}
      assert api.config["headers"] == %{"authorization" => "", "accept" => ""}

      assert Workflows.steps_needing_secrets(imported) == %{
               tg.id => ["bot_token"],
               api.id => ["headers"]
             }
    end

    test "a workflow without secrets is not flagged" do
      {:ok, wf} = Workflows.create_workflow(%{name: "no-secrets"})

      {:ok, _} =
        Workflows.add_step(wf, %{
          name: "fetch",
          skill: "web_fetch",
          config: %{"url" => "https://example.com"}
        })

      imported = wf.id |> Workflows.get_workflow!() |> Workflows.export_workflow() |> import!()
      assert Workflows.steps_needing_secrets(imported) == %{}
    end

    # Flags name step ids, which a new import does not share: a file never
    # carries them in, and an export never carries them out.
    test "flags are neither exported nor taken from the file" do
      {wf, _tg, _api} = workflow_with_secrets()
      imported = wf |> Workflows.export_workflow() |> import!()
      re_exported = Workflows.export_workflow(imported)

      refute Map.has_key?(re_exported["workflow"]["metadata"], "steps_needing_secrets")

      forged =
        put_in(re_exported, ["workflow", "metadata"], %{
          "steps_needing_secrets" => %{"999999" => ["x"]}
        })

      forged = Map.put(forged, "steps", [])

      assert Workflows.steps_needing_secrets(import!(forged)) == %{}
    end

    test "filling a step's secrets clears its flag; filling some does not" do
      {wf, _tg, _api} = workflow_with_secrets()
      imported = wf |> Workflows.export_workflow() |> import!()
      tg = Enum.find(imported.steps, &(&1.name == "tg"))
      api = Enum.find(imported.steps, &(&1.name == "api"))

      {:ok, _} =
        Workflows.update_step(tg, %{config: %{"bot_token" => "456:new", "chat_id" => "42"}})

      {:ok, _} =
        Workflows.update_step(api, %{
          config: %{
            "url" => "https://example.com",
            "headers" => %{"authorization" => "Bearer new", "accept" => ""}
          }
        })

      assert Workflows.steps_needing_secrets(Workflows.get_workflow!(imported.id)) == %{
               api.id => ["headers"]
             }
    end
  end
end
