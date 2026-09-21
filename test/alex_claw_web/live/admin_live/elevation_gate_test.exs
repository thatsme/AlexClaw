defmodule AlexClawWeb.AdminLive.ElevationGateTest do
  @moduledoc """
  Every control-plane write, driven the way an attacker would drive it.

  The events are pushed straight at the LiveView rather than clicked, because
  that is the threat: a hidden button is not a check, and a session that holds
  the admin password can send any event the page knows.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AuditLog, Elevation, Policy, TOTP}
  alias AlexClaw.{Cluster, LLM, Repo, Resources, Workflows}

  setup do
    sid = Elevation.new_sid()
    on_exit(fn -> Elevation.revoke(sid) end)

    {:ok, sid: sid, fixtures: fixtures()}
  end

  defp fixtures do
    {:ok, policy} =
      %Policy{}
      |> Policy.changeset(%{name: "gate-probe", rule_type: "rate_limit", config: %{}})
      |> Repo.insert()

    {:ok, provider} =
      LLM.create_provider(%{
        name: "gate-probe",
        type: "openai_compatible",
        tier: "light",
        model: "probe-1"
      })

    {:ok, resource} = Resources.create_resource(%{name: "gate-probe", type: "api"})
    # A second one, because the resources cases delete the first and the
    # workflow still needs something to be assigned.
    {:ok, spare} = Resources.create_resource(%{name: "gate-probe-spare", type: "api"})
    {:ok, node} = Cluster.create_node(%{name: "gate-probe", label: "probe"})
    {:ok, workflow} = Workflows.create_workflow(%{name: "gate-probe"})

    %{
      policy: policy,
      provider: provider,
      resource: resource,
      spare_resource: spare,
      node: node,
      workflow: workflow
    }
  end

  # Each case: where the event lives, what it needs pushed first to make the
  # page ready for it, and what in the database it would change if it went
  # through. `check` is read before and after — a refusal must leave it equal.
  defp cases(fixtures) do
    config_cases() ++
      policy_cases(fixtures) ++
      llm_cases(fixtures) ++
      resource_cases(fixtures) ++
      cluster_cases(fixtures) ++
      workflow_cases(fixtures)
  end

  defp config_cases do
    [
      %{
        page: "/config",
        event: "save",
        params: %{
          "key" => "gate.probe",
          "value" => "written",
          "type" => "string",
          "category" => "general"
        },
        check: fn -> stored("gate.probe") end
      },
      %{
        page: "/config",
        event: "delete",
        params: %{"key" => "identity.name"},
        check: fn -> stored("identity.name") end
      }
    ]
  end

  defp policy_cases(%{policy: policy}) do
    [
      %{
        page: "/policies",
        event: "create_policy",
        params: %{"policy" => %{"name" => "made-by-test", "rule_type" => "rate_limit"}},
        check: fn -> Repo.aggregate(Policy, :count) end
      },
      %{
        page: "/policies",
        event: "update_policy",
        params: %{
          "policy" => %{
            "id" => to_string(policy.id),
            "name" => "renamed",
            "rule_type" => "rate_limit"
          }
        },
        check: fn -> Repo.get!(Policy, policy.id).name end
      },
      %{
        page: "/policies",
        event: "toggle_policy",
        params: %{"id" => to_string(policy.id)},
        check: fn -> Repo.get!(Policy, policy.id).enabled end
      },
      %{
        page: "/policies",
        event: "delete_policy",
        params: %{"id" => to_string(policy.id)},
        check: fn -> Repo.aggregate(Policy, :count) end
      }
    ]
  end

  defp llm_cases(%{provider: provider}) do
    [
      %{
        page: "/llm",
        event: "save_provider",
        params: %{
          "name" => "made-by-test",
          "type" => "openai_compatible",
          "tier" => "light",
          "model" => "probe-1"
        },
        check: fn -> length(LLM.list_providers()) end
      },
      %{
        page: "/llm",
        event: "delete_provider",
        params: %{"id" => to_string(provider.id)},
        check: fn -> length(LLM.list_providers()) end
      }
    ]
  end

  defp resource_cases(%{resource: resource}) do
    [
      %{
        page: "/resources",
        event: "save",
        params: %{"name" => "made-by-test", "type" => "api", "enabled" => "true"},
        check: fn -> length(Resources.list_resources()) end
      },
      %{
        page: "/resources",
        event: "toggle_enabled",
        params: %{"id" => to_string(resource.id)},
        check: fn -> elem(Resources.get_resource(resource.id), 1).enabled end
      },
      %{
        page: "/resources",
        event: "delete",
        params: %{"id" => to_string(resource.id)},
        check: fn -> length(Resources.list_resources()) end
      }
    ]
  end

  defp cluster_cases(%{node: node}) do
    [
      %{
        page: "/cluster",
        event: "add_node",
        params: %{"name" => "made-by-test", "label" => "test"},
        check: fn -> length(Cluster.list_nodes()) end
      },
      %{
        page: "/cluster",
        event: "delete",
        params: %{"id" => to_string(node.id)},
        check: fn -> length(Cluster.list_nodes()) end
      }
    ]
  end

  defp workflow_cases(%{workflow: wf, spare_resource: resource}) do
    [
      %{
        page: "/workflows",
        event: "save_workflow",
        params: %{"name" => "made-by-test", "enabled" => "true"},
        check: fn -> length(Workflows.list_workflows()) end
      },
      %{
        page: "/workflows",
        event: "duplicate",
        params: %{"id" => to_string(wf.id)},
        check: fn -> length(Workflows.list_workflows()) end
      },
      %{
        page: "/workflows",
        event: "add_step",
        prepare: [{"edit", %{"id" => to_string(wf.id)}}],
        params: %{"step_name" => "probe", "step_skill" => "echo", "step_config" => "{}"},
        check: fn -> length(Workflows.get_workflow!(wf.id).steps) end
      },
      %{
        page: "/workflows",
        event: "assign_resource",
        prepare: [{"edit", %{"id" => to_string(wf.id)}}],
        params: %{"resource_id" => to_string(resource.id)},
        check: fn -> length(Workflows.get_workflow!(wf.id).resources) end
      },
      %{
        page: "/workflows",
        event: "delete",
        params: %{"id" => to_string(wf.id)},
        check: fn -> length(Workflows.list_workflows()) end
      }
    ]
  end

  defp stored(key) do
    setting = Repo.get_by(AlexClaw.Config.Setting, key: key)
    setting && setting.value
  end

  # Flash is rendered by the layout and never reaches these assertions, so a
  # refusal is observed where it is durable: the audit row, and the untouched
  # database. That is also the stronger claim — it says the gate refused, not
  # merely that the write failed.
  defp latest_refusal do
    AuditLog.recent(limit: 1, decision: "deny") |> List.first() |> Map.get(:reason)
  end

  defp refusals do
    Enum.count(AuditLog.recent(limit: 500, decision: "deny"), &(&1.caller_type == "admin"))
  end

  defp enable_totp do
    AlexClaw.Config.set("auth.totp.secret", Base.encode32(NimbleTOTP.secret(), padding: false),
      type: "string",
      category: "auth"
    )

    AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    # Somewhere to send the prompt, or Gate refuses before elevation is reached.
    AlexClaw.Config.set("telegram.chat_id", "123", type: "string", category: "telegram")
  end

  defp open(conn, sid, page) do
    {:ok, view, html} =
      conn
      |> authenticate(sid)
      |> live(page)

    {view, html}
  end

  defp send_event(view, %{} = test_case) do
    for {event, params} <- Map.get(test_case, :prepare, []) do
      render_click(view, event, params)
    end

    render_click(view, test_case.event, test_case.params)
  end

  describe "with 2FA enabled and no elevation" do
    test "every control-plane event is refused and changes nothing", ctx do
      enable_totp()

      for test_case <- cases(ctx.fixtures) do
        before = test_case.check.()
        refused_before = refusals()
        {view, _html} = open(ctx.conn, ctx.sid, test_case.page)
        send_event(view, test_case)

        assert test_case.check.() == before,
               "#{test_case.page} #{test_case.event} changed state without an elevation"

        assert refusals() == refused_before + 1,
               "#{test_case.page} #{test_case.event} did not record a refusal — " <>
                 "the write may have failed for some other reason"
      end
    end

    test "the page offers an unlock rather than pretending to be editable", ctx do
      enable_totp()

      {_view, html} = open(ctx.conn, ctx.sid, "/config")

      assert html =~ "Editing is locked"
      assert html =~ "Unlock editing"
    end
  end

  describe "with an elevation" do
    test "every control-plane event goes through", ctx do
      enable_totp()

      for test_case <- cases(ctx.fixtures) do
        {:ok, _expires_at} = Elevation.grant(ctx.sid)
        before = test_case.check.()
        {view, _html} = open(ctx.conn, ctx.sid, test_case.page)
        send_event(view, test_case)

        refute test_case.check.() == before,
               "#{test_case.page} #{test_case.event} left the database unchanged while elevated"
      end
    end

    test "the page says how long the unlock lasts", ctx do
      enable_totp()
      {:ok, _} = Elevation.grant(ctx.sid)

      {_view, html} = open(ctx.conn, ctx.sid, "/config")

      assert html =~ "Editing unlocked until"
    end
  end

  # An elevation that has run out and one that was revoked leave the same
  # state: no live row for the session. The fifteen-minute boundary itself is
  # covered in AlexClaw.Auth.ElevationTest, which can name the moment to judge
  # against instead of waiting for it.
  describe "once the elevation is over" do
    test "writes are refused again", ctx do
      enable_totp()
      {:ok, _} = Elevation.grant(ctx.sid)
      [test_case | _] = cases(ctx.fixtures)

      {view, _html} = open(ctx.conn, ctx.sid, test_case.page)
      :ok = Elevation.revoke(ctx.sid)

      before = test_case.check.()
      refused_before = refusals()
      send_event(view, test_case)

      assert test_case.check.() == before
      assert refusals() == refused_before + 1
    end
  end

  # Strict: no second factor is not a lesser protection, it is a closed door.
  # There is no state in which a control-plane write proceeds on the password.
  describe "with no second factor configured" do
    test "every control-plane event is refused and changes nothing", ctx do
      for test_case <- cases(ctx.fixtures) do
        before = test_case.check.()
        refused_before = refusals()
        {view, _html} = open(ctx.conn, ctx.sid, test_case.page)
        send_event(view, test_case)

        assert test_case.check.() == before,
               "#{test_case.page} #{test_case.event} took effect without a second factor"

        assert refusals() == refused_before + 1,
               "#{test_case.page} #{test_case.event} recorded no refusal"
      end
    end

    test "the refusal says why, and names the way out", ctx do
      [test_case | _] = cases(ctx.fixtures)
      {view, _html} = open(ctx.conn, ctx.sid, test_case.page)

      send_event(view, test_case)

      assert latest_refusal() =~ "no_second_factor"
    end

    test "an elevation cannot be obtained either", ctx do
      {view, _html} = open(ctx.conn, ctx.sid, "/config")

      render_click(view, "unlock_editing", %{})

      refute Elevation.elevated?(ctx.sid)
    end

    test "every gated page says the control plane is read-only", ctx do
      for page <- ~w(/config /policies /llm /resources /cluster /workflows /database) do
        {_view, html} = open(ctx.conn, ctx.sid, page)

        assert html =~ "Read-only — 2FA is not configured",
               "#{page} does not say that changes are refused"

        assert html =~ "Two-factor authentication",
               "#{page} does not say how to make changes possible"
      end
    end
  end

  describe "auth.totp.* is managed from a gateway" do
    test "an elevated session still cannot switch 2FA off", ctx do
      enable_totp()
      {:ok, _} = Elevation.grant(ctx.sid)

      {view, _html} = open(ctx.conn, ctx.sid, "/config")

      render_click(view, "save", %{
        "key" => "auth.totp.enabled",
        "value" => "false",
        "type" => "boolean",
        "category" => "auth"
      })

      assert stored("auth.totp.enabled") == "true"
      assert AlexClaw.Config.enabled?("auth.totp.enabled")
    end

    test "an elevated session cannot delete the flag either", ctx do
      enable_totp()
      {:ok, _} = Elevation.grant(ctx.sid)

      {view, _html} = open(ctx.conn, ctx.sid, "/config")

      render_click(view, "delete", %{"key" => "auth.totp.enabled"})

      assert stored("auth.totp.enabled") == "true"
      assert AlexClaw.Config.enabled?("auth.totp.enabled")
    end

    test "nor the secret behind it", ctx do
      enable_totp()
      {:ok, _} = Elevation.grant(ctx.sid)
      secret = TOTP.secret()

      {view, _html} = open(ctx.conn, ctx.sid, "/config")

      render_click(view, "save", %{
        "key" => "auth.totp.secret",
        "value" => "mine",
        "type" => "string"
      })

      assert TOTP.secret() == secret
    end

    test "ordinary auth keys are still editable under an elevation", ctx do
      enable_totp()
      {:ok, _} = Elevation.grant(ctx.sid)

      {view, _html} = open(ctx.conn, ctx.sid, "/config")

      render_click(view, "save", %{
        "key" => "auth.rate_limit.max_attempts",
        "value" => "9",
        "type" => "integer",
        "category" => "auth"
      })

      assert AlexClaw.Config.get("auth.rate_limit.max_attempts") in [9, "9"]
    end
  end
end
