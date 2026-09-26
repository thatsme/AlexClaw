defmodule AlexClaw.WebAutomation.RecordingSecretsTest do
  @moduledoc """
  Logins in recordings and recipes are references, bound to the site they
  were recorded on (reports/V040_SECURITY_DESIGN.md §6; 0.4.0 S4b).

  The sidecar now records a credential field as a slot — a fill with
  `secret: true` and no value (web-automator/tests/test_recorder_secrets.py).
  On the AlexClaw side:
  - `Recording.to_recipe/2` turns the captured actions into a recipe; a slot
    becomes a fill whose value is `%{"secret" => nil}`: a login still to be
    attached; any other fill keeps its value;
  - `Recording.login_slots/1` lists the selectors still waiting for a login;
  - a recipe with an empty slot cannot be played: `play/3` refuses with
    `{:login_required, selectors}` before contacting the sidecar;
  - `Recording.attach_login/3` stores the login in OpenBao, bound to the
    recipe's ORIGIN (scheme, host, port — the site it was recorded on), and
    puts the reference in the slot;
  - `Recording.resolved/1` hands back the recipe with every reference replaced
    by its value, resolved for that origin — what play sends to the sidecar;
    a reference to another origin is refused;
  - fill values typed into a web_automation STEP's inline recipe are stored
    as references too, bound to that recipe's origin;
  - the upgrade moves every fill value of an existing recording into OpenBao,
    bound to its origin: the old recorder never noted field types, so a
    password cannot be told from a search term, and a search term stored as
    a secret costs nothing.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.SafeExecutor
  alias AlexClaw.{Secrets, Workflows}
  alias AlexClaw.Skills.WebAutomation
  alias AlexClaw.WebAutomation.Recording

  @url "https://portal.example.com/login"
  @origin "origin:https://portal.example.com"
  @password "typed-password-#{System.unique_integer([:positive])}"

  # A process has no secret unless it is given one (S9 fix review N1): the
  # recipe's own logins, as the admin UI's replay grants them.
  defp as_owner(recipe, fun),
    do: SafeExecutor.with_secrets(Map.values(Recording.references(recipe)), fun)

  defp captured do
    [
      %{"action_type" => "fill", "selector" => "#user", "value" => "alex"},
      %{"action_type" => "fill", "selector" => "#pw", "secret" => true},
      %{"action_type" => "click", "selector" => "#submit"}
    ]
  end

  describe "turning a recording into a recipe" do
    test "a login slot is an empty reference; an ordinary fill keeps its value" do
      {:ok, recipe} = Recording.to_recipe(@url, captured())

      steps = recipe["steps"]
      assert Enum.at(steps, 0)["value"] == "alex"
      assert Enum.at(steps, 1)["value"] == %{"secret" => nil}
      assert Recording.login_slots(recipe) == ["#pw"]
    end
  end

  describe "a recipe with an empty login slot" do
    test "cannot be played, and the sidecar is never contacted" do
      {:ok, recipe} = Recording.to_recipe(@url, captured())

      assert {:error, {:login_required, ["#pw"]}} =
               AlexClaw.Skills.WebAutomation.play(recipe, [], deadline_ms: 5_000)
    end
  end

  describe "attaching a login" do
    test "stores it in OpenBao, bound to the recording's origin, and fills the slot" do
      {:ok, recipe} = Recording.to_recipe(@url, captured())
      {:ok, recipe} = Recording.attach_login(recipe, "#pw", @password)

      assert Recording.login_slots(recipe) == []
      assert %{"secret" => name} = Enum.at(recipe["steps"], 1)["value"]
      refute inspect(recipe) =~ @password

      assert Secrets.get(name).binding == [@origin]
    end

    test "resolved/1 hands back the value for that origin — what play sends" do
      {:ok, recipe} = Recording.to_recipe(@url, captured())
      {:ok, recipe} = Recording.attach_login(recipe, "#pw", @password)

      assert {:ok, resolved} = as_owner(recipe, fn -> Recording.resolved(recipe) end)
      assert Enum.at(resolved["steps"], 1)["value"] == @password
      assert Enum.at(resolved["steps"], 0)["value"] == "alex"
    end

    test "a recipe moved to another site does not get the login" do
      {:ok, recipe} = Recording.to_recipe(@url, captured())
      {:ok, recipe} = Recording.attach_login(recipe, "#pw", @password)

      moved = %{recipe | "url" => "https://evil.example/login"}
      assert {:error, {:not_bound, _}} = Recording.resolved(moved)
    end
  end

  describe "a web_automation step's inline recipe" do
    test "stores its fill values as references bound to the recipe's origin" do
      # Since 0.3.54 a step saves only when its skill is available.
      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")
      {:ok, wf} = Workflows.create_workflow(%{name: "S4b #{System.unique_integer([:positive])}"})

      {:ok, step} =
        Workflows.add_step(wf, %{
          name: "Login",
          skill: "web_automation",
          config: %{
            "url" => @url,
            "steps" => [
              %{"action" => "fill", "selector" => "#pw", "value" => @password},
              %{"action" => "click", "selector" => "#submit"}
            ]
          }
        })

      %{rows: [[raw]]} =
        Repo.query!("SELECT config::text FROM workflow_steps WHERE id = $1", [step.id])

      refute raw =~ @password
      [name] = Regex.run(~r/"secret":\s*"([^"]+)"/, raw, capture: :all_but_first)
      assert Secrets.get(name).binding == [@origin]
    end
  end

  # What actually crosses to the sidecar: the resolved value, in the play
  # request, and nowhere else. (Reaching the sidecar from a test, as reported:
  # web_automator.host at a Bypass, web_automator.enabled, and a
  # :web_automator_token in the app env; POST /play receives
  # {play_id, deadline_ms, config}.)
  describe "playing a recipe with an attached login" do
    setup do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.stub(bypass, "POST", "/play", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:played, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "success", "results" => []}))
      end)

      insert_setting("web_automator.enabled", "true", type: "boolean", category: "web_automator")

      insert_setting("web_automator.host", "http://localhost:#{bypass.port}",
        type: "string",
        category: "web_automator"
      )

      previous = Application.get_env(:alex_claw, :web_automator_token)
      Application.put_env(:alex_claw, :web_automator_token, "test-sidecar-token")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:alex_claw, :web_automator_token, previous),
          else: Application.delete_env(:alex_claw, :web_automator_token)
      end)

      :ok
    end

    test "the sidecar receives the login's value, resolved for the recipe's origin" do
      {:ok, recipe} = Recording.to_recipe(@url, captured())
      {:ok, recipe} = Recording.attach_login(recipe, "#pw", @password)

      assert {:ok, _, :on_success} =
               as_owner(recipe, fn -> WebAutomation.play(recipe, [], deadline_ms: 5_000) end)

      assert_receive {:played, %{"config" => config}}
      assert Enum.at(config["steps"], 1)["value"] == @password
      refute inspect(config) =~ ~s("secret"), "a reference reached the sidecar"
    end
  end

  describe "the upgrade" do
    test "moves every fill value of an existing recording into OpenBao, bound to its origin" do
      res_id =
        AlexClawTest.Legacy.insert_resource(@url, %{
          "url" => @url,
          "steps" => [
            %{"action" => "fill", "selector" => "#user", "value" => "alex"},
            %{"action" => "fill", "selector" => "#pw", "value" => @password}
          ]
        })

      assert {:ok, _report} = AlexClaw.Config.SecretUpgrade.run()

      %{rows: [[meta]]} =
        Repo.query!("SELECT metadata::text FROM resources WHERE id = $1", [res_id])

      refute meta =~ @password

      refute meta =~ ~s("alex"),
             "every recorded fill value moves — field types were never recorded"

      {:ok, resource} = AlexClaw.Resources.get_resource(res_id)
      recipe = Map.take(resource.metadata, ["url", "steps"])

      assert {:ok, resolved} = as_owner(recipe, fn -> Recording.resolved(recipe) end)
      assert Enum.map(resolved["steps"], & &1["value"]) == ["alex", @password]
    end
  end
end
