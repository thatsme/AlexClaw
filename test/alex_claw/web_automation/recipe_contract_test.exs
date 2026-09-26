defmodule AlexClaw.WebAutomation.RecipeContractTest do
  @moduledoc """
  The recipe contract, AlexClaw side (reports/WEB_AUTOMATOR_TARGET.md §2).

  AlexClaw.WebAutomation.Recipe.validate/1 accepts every valid fixture and
  refuses every invalid one in web-automator/tests/contract/recipes.json — the
  same file the sidecar's pydantic model is tested against. If the two sides
  disagree on a recipe, the side that disagrees with the file is red.

  And AlexClaw uses it: play/2 validates before sending, so an invalid recipe
  never reaches the sidecar; a recording is stored only as a valid recipe;
  and every answer the sidecar can give maps to a typed result instead of a
  CaseClauseError.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.{ControlPlane, Repo}
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Skills.WebAutomation
  alias AlexClaw.WebAutomation.Recipe

  import Ecto.Query

  @contract "web-automator/tests/contract"
  @external_resource Path.join(@contract, "recipes.json")
  @external_resource Path.join(@contract, "actions.json")
  @fixtures @contract |> Path.join("recipes.json") |> File.read!() |> Jason.decode!()
  @actions @contract |> Path.join("actions.json") |> File.read!() |> Jason.decode!()

  @valid %{"url" => "https://example.com", "steps" => []}

  describe "validate/1 against the shared fixtures" do
    for %{"name" => name, "recipe" => recipe} <- @fixtures["valid"] do
      test "valid: #{name}" do
        assert {:ok, _} = Recipe.validate(unquote(Macro.escape(recipe)))
      end
    end

    for %{"name" => name, "recipe" => recipe, "reason" => reason} <- @fixtures["invalid"] do
      test "invalid: #{name} (#{reason})" do
        assert {:error, reasons} = Recipe.validate(unquote(Macro.escape(recipe)))
        assert is_list(reasons) and reasons != []
      end
    end

    test "the action set is the contract" do
      assert Enum.sort(Recipe.actions()) == Enum.sort(@actions)
    end
  end

  describe "AlexClaw uses the contract" do
    setup do
      bypass = Bypass.open()

      insert_setting("web_automator.host", "http://localhost:#{bypass.port}",
        type: "string",
        category: "web_automator"
      )

      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      Application.put_env(:alex_claw, :web_automator_token, "test-automator-token")
      on_exit(fn -> Application.delete_env(:alex_claw, :web_automator_token) end)

      %{bypass: bypass}
    end

    # Bypass has nothing stubbed: a request that reaches it fails the test.
    test "play/2 refuses an invalid recipe before sending it" do
      for %{"recipe" => recipe} <- @fixtures["invalid"] do
        assert {:error, {:invalid_recipe, reasons}} = WebAutomation.play(recipe, [])
        assert reasons != []
      end
    end

    test "busy (409) is :busy", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        json(conn, 409, %{"detail" => "Cannot play: currently playing"})
      end)

      assert {:error, :busy} = WebAutomation.play(@valid, [])
    end

    test "a 422 from the sidecar is :invalid_recipe with its detail", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        json(conn, 422, %{"detail" => [%{"loc" => ["body", "config", "url"], "msg" => "bad"}]})
      end)

      assert {:error, {:invalid_recipe, detail}} = WebAutomation.play(@valid, [])
      assert detail != nil
    end

    test "a failed run keeps its partial results", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        json(conn, 200, %{
          "status" => "error",
          "error" => "selector #password not found",
          "downloads" => ["/tmp/downloads/a.csv"],
          "screenshots" => [],
          "scraped_data" => [%{"type" => "text", "text" => "partial"}]
        })
      end)

      assert {:error, {:automation_failed, "selector #password not found", partial}} =
               WebAutomation.play(@valid, [])

      assert partial["scraped_data"] == [%{"type" => "text", "text" => "partial"}]
    end

    test "an unexpected status is an error, not a crash", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        json(conn, 200, %{"status" => "half-done"})
      end)

      assert {:error, {:unexpected_response, _}} = WebAutomation.play(@valid, [])
    end

    test "a record answer without its fields is an error, not a crash", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/record", fn conn ->
        json(conn, 200, %{"session" => "abc"})
      end)

      assert {:error, {:unexpected_response, _}} =
               WebAutomation.record(%{"url" => "https://example.com"})
    end
  end

  # A recording is stored as an automation resource whose metadata is the
  # recipe (phase-2 item 3 result, §2). It was not validated when stored: a
  # summary without base_url was saved with "url" => "unknown", which the
  # contract refuses at play time — a recipe that can never run. Now a
  # recording is validated before it is saved; one that is not a valid recipe
  # is not saved, and the caller is told. Since 0.4.0 (S5b) a recording is
  # stopped from the admin UI, through the one door (record, elevation).
  describe "a recording is stored only as a valid recipe" do
    setup do
      bypass = Bypass.open()

      insert_setting("web_automator.host", "http://localhost:#{bypass.port}",
        type: "string",
        category: "web_automator"
      )

      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      Application.put_env(:alex_claw, :web_automator_token, "test-automator-token")
      on_exit(fn -> Application.delete_env(:alex_claw, :web_automator_token) end)

      sid = AlexClaw.Auth.Elevation.new_sid()
      {:ok, _} = AlexClaw.Auth.Elevation.grant(sid)

      on_exit(fn ->
        AlexClaw.SandboxCleanup.run(fn -> AlexClaw.Auth.Elevation.revoke(sid) end)
      end)

      %{bypass: bypass, sid: sid}
    end

    # Since 0.4.0 (S4b) a STORED recording holds its fill values as references
    # to OpenBao, so it is checked by Recording.validate/1 (the contract with
    # logins blank). Recipe.validate/1 is for what is SENT to the sidecar,
    # where every value is text once resolved.
    test "a recording is stored as a recipe the contract accepts", %{bypass: bypass, sid: sid} do
      assert {:ok, _} =
               stop_with(bypass, sid, %{
                 "base_url" => "https://example.com/search",
                 "captured_actions" => 3
               })

      assert [recipe] = stored_recipes()
      assert {:ok, _} = AlexClaw.WebAutomation.Recording.validate(recipe)

      assert Enum.any?(
               recipe["steps"],
               &(&1 == %{"action" => "check", "selector" => "#exact", "checked" => false})
             )
    end

    test "a recording without a start url is not stored, and the caller is told why", %{
      bypass: bypass,
      sid: sid
    } do
      assert {:error, reasons} = stop_with(bypass, sid, %{"captured_actions" => 3})

      assert stored_recipes() == []
      assert reasons != [] and reasons != nil
    end
  end

  defp stop_with(bypass, sid, summary) do
    Bypass.expect_once(bypass, "POST", "/record/abc12345/stop", fn conn ->
      json(conn, 200, %{
        "actions" => [
          %{"action_type" => "fill", "selector" => "#q", "value" => "elixir"},
          %{"action_type" => "check", "selector" => "#exact", "checked" => false},
          %{"action_type" => "click", "selector" => "button"}
        ],
        "downloads" => [],
        "summary" => summary
      })
    end)

    ControlPlane.perform(:record, %{stop: "abc12345"}, Context.admin_ui(sid))
  end

  defp stored_recipes do
    Repo.all(from(r in "resources", where: r.type == "automation", select: r.metadata))
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
