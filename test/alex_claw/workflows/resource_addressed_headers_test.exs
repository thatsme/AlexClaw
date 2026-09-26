defmodule AlexClaw.Workflows.ResourceAddressedHeadersTest do
  @moduledoc """
  An api_request step addressed through its workflow's API resource keeps its
  headers (S10 review N1; ruling: into 0.4.0, no credential lost at upgrade).

  Since every header is a secret, a header needs a host to be bound to. A
  step whose URL is `{base_url}…`, or which gives only a `path`, names no host
  itself: the request goes to the workflow's API resource, so its headers are
  bound to that resource's host, as `api_request` addresses it (the
  discovered API base, else the resource's URL), when they are entered. They
  are saved, sent at run time, and carried over by the boot upgrade. With no
  API resource on the workflow there is still nowhere to bind them, and the
  save is refused.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Config.SecretUpgrade
  alias AlexClaw.{Resources, Secrets, Workflows}
  alias AlexClaw.Skills.CircuitBreaker
  alias AlexClaw.Workflows.Executor
  alias AlexClawTest.Legacy
  alias Ecto.Adapters.SQL.Sandbox

  @value "resource-addressed-#{System.unique_integer([:positive])}"

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    CircuitBreaker.reset("api_request")

    {:ok, wf} =
      Workflows.create_workflow(%{name: "addressed #{System.unique_integer()}", enabled: true})

    %{wf: wf}
  end

  defp with_api_resource(wf, url) do
    {:ok, resource} =
      Resources.create_resource(
        %{
          name: "api #{System.unique_integer([:positive])}",
          type: "api",
          url: url,
          metadata: %{}
        },
        skip_discovery: true
      )

    {:ok, _} = Workflows.assign_resource(wf, resource.id)
    resource
  end

  defp config(id) do
    %{rows: [[config]]} = Repo.query!("SELECT config FROM workflow_steps WHERE id = $1", [id])
    config
  end

  for {what, addressing} <- [
        {"a {base_url} URL", %{"url" => "{base_url}/x"}},
        {"a path", %{"path" => "/x"}}
      ] do
    test "a header on a step addressed by #{what} is bound to the resource's host", %{wf: wf} do
      with_api_resource(wf, "https://api.example.com")

      {:ok, step} =
        Workflows.add_step(wf, %{
          name: "Call",
          skill: "api_request",
          config: Map.put(unquote(Macro.escape(addressing)), "headers", %{"X-Key" => @value})
        })

      assert %{"secret" => name} = step.config["headers"]["X-Key"]
      assert Secrets.value_matches?(name, @value)
      assert Secrets.get(name).binding == ["host:api.example.com"]
    end
  end

  test "the header is sent to the resource at run time", %{wf: wf} do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect_once(bypass, "GET", "/x", fn conn ->
      send(test_pid, {:headers, conn.req_headers})
      Plug.Conn.resp(conn, 200, "ok")
    end)

    with_api_resource(wf, "http://localhost:#{bypass.port}")

    {:ok, _step} =
      Workflows.add_step(wf, %{
        name: "Call",
        skill: "api_request",
        config: %{"url" => "{base_url}/x", "headers" => %{"X-Key" => @value}}
      })

    assert {:ok, _run} = Executor.run(wf.id)
    assert_receive {:headers, headers}
    assert {"x-key", @value} in headers
  end

  test "with no API resource on the workflow, the save is still refused", %{wf: wf} do
    assert {:error, _changeset} =
             Workflows.add_step(wf, %{
               name: "Call",
               skill: "api_request",
               config: %{"url" => "{base_url}/x", "headers" => %{"X-Key" => @value}}
             })
  end

  test "the upgrade carries a 0.3.x header of such a step over, bound to the resource's host",
       %{wf: wf} do
    Legacy.clear_declared_secrets()
    with_api_resource(wf, "https://api.example.com")

    id =
      Legacy.insert_step(wf.id, "api_request", %{
        "url" => "{base_url}/x",
        "headers" => %{"Accept" => "application/json", "Authorization" => "Bearer legacy"}
      })

    assert {:ok, report} = SecretUpgrade.run()
    assert "step #{id}" in report.records_moved

    headers = config(id)["headers"]

    for {header, value} <- [{"Accept", "application/json"}, {"Authorization", "Bearer legacy"}] do
      assert %{"secret" => name} = headers[header]
      assert Secrets.value_matches?(name, value)
      assert Secrets.get(name).binding == ["host:api.example.com"]
    end
  end
end
