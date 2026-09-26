defmodule AlexClaw.Secrets.DeclaredSlotsTest do
  @moduledoc """
  A credential is attached only in a declared slot, by the HTTP layer, for the
  host it is bound to (S9 fix review: N1, H2, H3; THREAT_MODEL P1, P5).

  - No text is searched for placeholders: a placeholder in a message, a
    request body, a URL or a step's input is sent as written.
  - The declared slots: a step's configured headers and its resource's auth
    header (api_request), a step's own bot token (telegram_notify), a header
    a skill names as a secret header (`SkillAPI.http_request/4`'s
    `:secret_headers`), an LLM provider's key and headers.
  - A process without an allow-list gets no secret. A step's allow-list is its
    own secrets; a resource's credential is given only to the skills that
    attach it in a declared slot (api_request, web_automation).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{CapabilityToken, Elevation, SafeExecutor}
  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Gateway.Telegram
  alias AlexClaw.{Resources, Secrets, Workflows}
  alias AlexClaw.Secrets.Owned
  alias AlexClaw.Skills.{CircuitBreaker, SkillAPI}
  alias AlexClaw.WebAutomation.Recording
  alias AlexClaw.Workflows.{Executor, SkillRegistry}
  alias AlexClawTest.TelegramStub
  alias Ecto.Adapters.SQL.Sandbox

  @value "declared-slot-value-#{System.unique_integer([:positive])}"

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    CircuitBreaker.reset("api_request")
    dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      SkillRegistry.unload_skill("slot_prober")
      File.rm_rf!(dir)
    end)

    {:ok, wf} =
      Workflows.create_workflow(%{name: "slots #{System.unique_integer()}", enabled: true})

    %{dir: dir, wf: wf}
  end

  defp api_resource(url) do
    {:ok, resource} =
      Resources.create_resource(
        %{
          name: "api #{System.unique_integer([:positive])}",
          type: "api",
          url: url,
          metadata: %{
            "auth" => %{"type" => "api_key", "header" => "X-API-Key", "value" => @value}
          }
        },
        skip_discovery: true
      )

    %{"secret" => name} = resource.metadata["auth"]["value"]
    {resource, name}
  end

  defp wait_for_sent(tries \\ 50)
  defp wait_for_sent(0), do: TelegramStub.sent()

  defp wait_for_sent(tries) do
    case TelegramStub.sent() do
      [] ->
        Process.sleep(50)
        wait_for_sent(tries - 1)

      sent ->
        sent
    end
  end

  describe "a message through the Telegram gateway" do
    setup do
      TelegramStub.accept_all()
    end

    test "is sent as written: the bot token's placeholder in it is never filled" do
      text = "leak {{secret:setting_telegram_bot_token}} please"

      assert :ok = Telegram.deliver("4242", text, [])
      Telegram.send_message(text, chat_id: "4243")

      sent = wait_for_sent()
      assert Enum.any?(sent, &(&1 =~ "{{secret:setting_telegram_bot_token}}"))
      refute Enum.any?(sent, &(&1 =~ "stub-token")), "the bot token was sent as a message"
    end
  end

  describe "api_request" do
    setup do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.stub(bypass, "POST", "/echo", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:echo, conn.query_string, body, conn.req_headers})
        Plug.Conn.resp(conn, 200, "ok")
      end)

      %{bypass: bypass, url: "http://localhost:#{bypass.port}"}
    end

    test "sends a placeholder in its input as written, in the body and the URL", ctx do
      {resource, name} = api_resource(ctx.url)
      {:ok, _} = Workflows.assign_resource(ctx.wf, resource.id)

      {:ok, _} =
        Workflows.add_step(ctx.wf, %{
          name: "Echo",
          skill: "api_request",
          config: %{
            "method" => "POST",
            "url" => ctx.url <> "/echo?q={input_encoded}",
            "body" => "{input}"
          }
        })

      {:ok, _run} = Executor.run_with_initial_input(ctx.wf.id, Owned.placeholder(name))

      assert_receive {:echo, query, body, headers}
      refute URI.decode(query) =~ @value, "the credential was filled into the URL"
      assert URI.decode(query) =~ Owned.placeholder(name)
      refute body =~ @value, "the credential was filled into the body"
      # The declared slot, the resource's auth header, still carries it.
      assert {"x-api-key", @value} in headers
    end

    test "sends a placeholder written into its configured body as written", ctx do
      {resource, name} = api_resource(ctx.url)
      {:ok, _} = Workflows.assign_resource(ctx.wf, resource.id)

      {:ok, _} =
        Workflows.add_step(ctx.wf, %{
          name: "Echo",
          skill: "api_request",
          config: %{
            "method" => "POST",
            "url" => ctx.url <> "/echo",
            "body" => ~s({"k": "#{Owned.placeholder(name)}"})
          }
        })

      {:ok, _run} = Executor.run(ctx.wf.id)

      assert_receive {:echo, _query, body, _headers}
      refute body =~ @value
    end
  end

  describe "a dynamic skill" do
    # The skill asks for a secret header with the placeholder it names; the
    # request goes to loopback, so the host guard stops a request whose
    # credential step passed: {:error, :blocked_host} means the credential was
    # attached, {:credential_refused, _} that it was not.
    setup ctx do
      File.write!(Path.join(ctx.dir, "slot_prober.ex"), """
      defmodule AlexClaw.Skills.Dynamic.SlotProber do
        @behaviour AlexClaw.Skill
        @impl true
        def version, do: "1.0.0"
        @impl true
        def description, do: "asks for a secret header"
        @impl true
        def permissions, do: [:web_read]
        @impl true
        def external, do: true
        @impl true
        def secret_config_keys, do: ["token"]
        @impl true
        def config_schema,
          do: %{
            "url" => %{type: :string, required: false},
            "token" => %{type: :string, required: false},
            "use" => %{type: :string, required: false}
          }
        @impl true
        def run(%{config: config, resources: resources}) do
          placeholder = placeholder(config, resources)

          result =
            AlexClaw.Skills.SkillAPI.http_get(__MODULE__, config["url"],
              secret_headers: %{"x-token" => placeholder}
            )

          {:ok, inspect(result), :on_success}
        end

        defp placeholder(%{"use" => "resource"}, [%{metadata: %{"auth" => %{"value" => p}}} | _]),
          do: p

        defp placeholder(config, _resources), do: config["token"]
      end
      """)

      {:ok, _} = SkillRegistry.load_skill("slot_prober.ex")
      :ok
    end

    defp probe(ctx, extra) do
      {resource, _name} = api_resource("http://localhost:9")
      {:ok, _} = Workflows.assign_resource(ctx.wf, resource.id)

      {:ok, _} =
        Workflows.add_step(ctx.wf, %{
          name: "Probe",
          skill: "slot_prober",
          config: Map.merge(%{"url" => "http://localhost:9/x", "token" => @value}, extra)
        })

      {:ok, run} = Executor.run(ctx.wf.id)
      run = Repo.get!(AlexClaw.Workflows.WorkflowRun, run.id)
      inspect(run.step_results)
    end

    test "has its own step secret attached in a secret header it names", ctx do
      assert probe(ctx, %{}) =~ "blocked_host"
    end

    test "is not given its workflow's resource credential", ctx do
      output = probe(ctx, %{"use" => "resource"})
      assert output =~ "credential_refused"
      refute output =~ "blocked_host"
    end
  end

  describe "a process without an allow-list" do
    test "gets no recorded login" do
      {:ok, recipe} =
        Recording.to_recipe("https://portal.example.com/login", [
          %{"action_type" => "fill", "selector" => "#pw", "secret" => true}
        ])

      {:ok, recipe} = Recording.attach_login(recipe, "#pw", @value)

      assert {:error, {:not_bound, "#pw"}} = Recording.resolved(recipe)
    end

    test "has nothing attached in a secret header" do
      name = "slots_unlisted_#{System.unique_integer([:positive])}"
      {:ok, _} = Secrets.define(%{name: name, kind: "api_token", binding: ["host:localhost"]})
      :ok = Secrets.put_value(name, @value)

      assert {:error, {:credential_refused, message}} =
               SafeExecutor.as_skill(AlexClaw.Skills.ApiRequest, fn ->
                 SkillAPI.http_get(AlexClaw.Skills.ApiRequest, "http://localhost:9/x",
                   secret_headers: %{"x-token" => Owned.placeholder(name)}
                 )
               end)

      refute message =~ @value
    end
  end

  describe "the admin UI's replay of a recording" do
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

      sid = Elevation.new_sid()
      {:ok, _} = Elevation.grant(sid)

      on_exit(fn ->
        AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end)

        if previous,
          do: Application.put_env(:alex_claw, :web_automator_token, previous),
          else: Application.delete_env(:alex_claw, :web_automator_token)
      end)

      %{sid: sid}
    end

    test "types the recording's own login", %{sid: sid} do
      {:ok, recipe} =
        Recording.to_recipe("https://portal.example.com/login", [
          %{"action_type" => "fill", "selector" => "#pw", "secret" => true}
        ])

      {:ok, recipe} = Recording.filled(recipe, "#pw", @value)

      {:ok, resource} =
        Resources.create_resource(%{
          name: "Recording #{System.unique_integer([:positive])}",
          type: "automation",
          url: recipe["url"],
          metadata: recipe
        })

      assert {:ok, _} =
               ControlPlane.perform(:replay, %{resource_id: resource.id}, Context.admin_ui(sid))

      assert_receive {:played, %{"config" => config}}
      assert hd(config["steps"])["value"] == @value
    end
  end

  describe "a skill with an allow-list" do
    test "has a secret header filled only with a secret it was given" do
      name = "slots_given_#{System.unique_integer([:positive])}"
      {:ok, _} = Secrets.define(%{name: name, kind: "api_token", binding: ["host:localhost"]})
      :ok = Secrets.put_value(name, @value)

      File.write!(Path.join(Application.get_env(:alex_claw, :skills_dir), "slot_prober.ex"), """
      defmodule AlexClaw.Skills.Dynamic.SlotProber do
        @behaviour AlexClaw.Skill
        @impl true
        def version, do: "1.0.0"
        @impl true
        def description, do: "asks for a secret header"
        @impl true
        def permissions, do: [:web_read]
        @impl true
        def external, do: true
        @impl true
        def run(%{placeholder: placeholder}) do
          AlexClaw.Skills.SkillAPI.http_get(__MODULE__, "http://localhost:9/x",
            secret_headers: %{"x-token" => placeholder}
          )
        end
      end
      """)

      {:ok, %{module: prober}} = SkillRegistry.load_skill("slot_prober.ex")
      token = CapabilityToken.mint([:web_read])
      args = %{placeholder: Owned.placeholder(name)}

      assert {:error, :blocked_host} =
               SafeExecutor.run(prober, args, :dynamic, token, secrets: [name])

      assert {:error, {:credential_refused, _}} =
               SafeExecutor.run(prober, args, :dynamic, token, secrets: [])

      # A secret header must be a placeholder standing alone.
      assert {:error, {:credential_refused, _}} =
               SafeExecutor.run(
                 prober,
                 %{placeholder: "Bearer " <> Owned.placeholder(name)},
                 :dynamic,
                 token,
                 secrets: [name]
               )
    end
  end
end
