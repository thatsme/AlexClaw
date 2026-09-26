defmodule AlexClaw.StepAndResourceSecretsTest do
  @moduledoc """
  Secrets inside workflows and resources are references, never values
  (reports/V040_SECURITY_DESIGN.md §5, §6; THREAT_MODEL.md P1, P5; 0.4.0 S4a).

  A step or resource field that holds a credential — telegram_notify's
  custom `bot_token`, an `api_request` credential header, a resource's
  `auth` value — is declared secret (the skill's `secret_config_keys/0`,
  and, for headers, a declared set of credential header names). On save:
  - the value goes to OpenBao, as a secret named after its owner, and the
    stored config holds only a reference `%{"secret" => name}`;
  - the secret is BOUND to the host the step or resource sends it to AT THE
    MOMENT IT IS ENTERED. Unlike settings, it does not follow a later edit:
    changing the host with the old credential kept is refused — moving a
    credential to a new destination is always a deliberate re-entry;
  - at run time the skill gets a placeholder, and the value is attached as
    the request is sent, for that host only (since S9, S8 H2/H3:
    credentials_at_send_test.exs); nothing else ever sees it;
  - a URL carrying user:password is refused outright.
  The upgrade carries existing values over like settings (the hard
  requirement).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.{Resources, Secrets, Workflows}
  alias AlexClaw.Workflows.Executor
  alias Ecto.Adapters.SQL.Sandbox

  @value "step-secret-#{System.unique_integer([:positive])}"

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "GET", "/data", fn conn ->
      send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
      Plug.Conn.resp(conn, 200, "ok")
    end)

    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "S4 #{System.unique_integer([:positive])}",
        enabled: true
      })

    %{bypass: bypass, wf: wf, url: "http://localhost:#{bypass.port}/data"}
  end

  defp stored_config(step_id) do
    %{rows: [[config]]} =
      Repo.query!("SELECT config::text FROM workflow_steps WHERE id = $1", [step_id])

    config
  end

  defp api_step(wf, url, auth) do
    Workflows.add_step(wf, %{
      name: "Fetch",
      skill: "api_request",
      config: %{
        "url" => url,
        "headers" => %{"Authorization" => auth, "Accept" => "application/json"}
      }
    })
  end

  describe "a credential header on an api_request step" do
    test "is stored as a reference; the value is in OpenBao, bound to the step's host", %{
      wf: wf,
      url: url
    } do
      {:ok, step} = api_step(wf, url, "Bearer " <> @value)

      raw = stored_config(step.id)
      refute raw =~ @value, "the credential is stored in the step config"
      assert raw =~ ~s("secret")
      assert raw =~ "application/json", "a non-credential header stays as it is"

      [name] = Regex.run(~r/"secret":\s*"([^"]+)"/, raw, capture: :all_but_first)
      assert Secrets.get(name).binding == ["host:localhost"]
    end

    test "the run sends the value to that host", %{wf: wf, url: url} do
      {:ok, _} = api_step(wf, url, "Bearer " <> @value)

      assert {:ok, _run} = Executor.run(wf.id)
      assert_receive {:auth, ["Bearer " <> @value]}
    end

    test "changing the host while keeping the credential is refused", %{wf: wf, url: url} do
      {:ok, step} = api_step(wf, url, "Bearer " <> @value)
      kept = step.config["headers"]["Authorization"]

      assert {:error, changeset} =
               Workflows.update_step(step, %{
                 config: %{
                   "url" => "https://evil.example/data",
                   "headers" => %{"Authorization" => kept}
                 }
               })

      assert inspect(changeset.errors) =~ ~r/credential|re-?enter/i
    end

    test "re-entering the credential for the new host is allowed, and rebinds it", %{
      wf: wf,
      url: url
    } do
      {:ok, step} = api_step(wf, url, "Bearer " <> @value)

      assert {:ok, updated} =
               Workflows.update_step(step, %{
                 config: %{
                   "url" => "https://api.other.example/data",
                   "headers" => %{"Authorization" => "Bearer new"}
                 }
               })

      [name] =
        Regex.run(~r/"secret":\s*"([^"]+)"/, stored_config(updated.id), capture: :all_but_first)

      assert Secrets.get(name).binding == ["host:api.other.example"]
    end

    test "deleting the step deletes its secret", %{wf: wf, url: url} do
      {:ok, step} = api_step(wf, url, "Bearer " <> @value)

      [name] =
        Regex.run(~r/"secret":\s*"([^"]+)"/, stored_config(step.id), capture: :all_but_first)

      {:ok, _} = Workflows.remove_step(step)
      assert is_nil(Secrets.get(name))
    end
  end

  describe "telegram_notify's own bot token" do
    test "is stored as a reference, bound to the Telegram API host" do
      AlexClawTest.TelegramStub.accept_all()

      {:ok, wf} =
        Workflows.create_workflow(%{name: "S4 tg #{System.unique_integer([:positive])}"})

      {:ok, step} =
        Workflows.add_step(wf, %{
          name: "Notify",
          skill: "telegram_notify",
          config: %{"bot_token" => "123-" <> @value, "chat_id" => "42"}
        })

      raw = stored_config(step.id)
      refute raw =~ @value
      # Not only absent (an encrypted 0.3.x config would pass that): replaced
      # by a reference.
      assert raw =~ ~s("secret")
      assert raw =~ ~s("chat_id")
    end
  end

  describe "a resource's credential" do
    test "is stored as a reference, bound to the resource's host" do
      {:ok, res} =
        Resources.create_resource(%{
          name: "API #{System.unique_integer([:positive])}",
          type: "api",
          url: "https://api.example.com",
          metadata: %{"auth" => %{"header" => "Authorization", "value" => "Bearer " <> @value}}
        })

      %{rows: [[meta]]} =
        Repo.query!("SELECT metadata::text FROM resources WHERE id = $1", [res.id])

      refute meta =~ @value
      [name] = Regex.run(~r/"secret":\s*"([^"]+)"/, meta, capture: :all_but_first)
      assert Secrets.get(name).binding == ["host:api.example.com"]
    end

    test "changing its host while keeping the credential is refused" do
      {:ok, res} =
        Resources.create_resource(%{
          name: "API #{System.unique_integer([:positive])}",
          type: "api",
          url: "https://api.example.com",
          metadata: %{"auth" => %{"header" => "Authorization", "value" => "Bearer " <> @value}}
        })

      assert {:error, changeset} =
               Resources.update_resource(res, %{
                 url: "https://evil.example",
                 metadata: res.metadata
               })

      assert inspect(changeset.errors) =~ ~r/credential|re-?enter/i
    end
  end

  describe "a URL with a password in it" do
    test "is refused on a resource" do
      assert {:error, changeset} =
               Resources.create_resource(%{
                 name: "Userinfo #{System.unique_integer([:positive])}",
                 type: "website",
                 url: "https://admin:#{@value}@internal.example.com/"
               })

      assert changeset.errors[:url]
    end

    test "is refused on an api_request step", %{wf: wf} do
      assert {:error, changeset} =
               Workflows.add_step(wf, %{
                 name: "Fetch",
                 skill: "api_request",
                 config: %{"url" => "https://admin:#{@value}@internal.example.com/"}
               })

      assert inspect(changeset.errors) =~ "url"
    end
  end

  describe "the upgrade carries existing values over" do
    test "a 0.3.x step credential and resource auth move to OpenBao, unchanged" do
      {:ok, wf} =
        Workflows.create_workflow(%{name: "Legacy #{System.unique_integer([:positive])}"})

      step_id =
        AlexClawTest.Legacy.insert_step(wf.id, "api_request", %{
          "url" => "https://api.legacy.example/x",
          "headers" => %{"Authorization" => "Bearer legacy-" <> @value}
        })

      res_id =
        AlexClawTest.Legacy.insert_resource("https://api.legacy.example", %{
          "auth" => %{"header" => "Authorization", "value" => "Bearer legacy-res-" <> @value}
        })

      assert {:ok, _report} = AlexClaw.Config.SecretUpgrade.run()

      refute stored_config(step_id) =~ @value

      %{rows: [[meta]]} =
        Repo.query!("SELECT metadata::text FROM resources WHERE id = $1", [res_id])

      refute meta =~ @value

      [step_secret] =
        Regex.run(~r/"secret":\s*"([^"]+)"/, stored_config(step_id), capture: :all_but_first)

      assert {:ok, "Bearer legacy-" <> @value} =
               Secrets.resolve(step_secret, for: "host:api.legacy.example")
    end
  end
end
