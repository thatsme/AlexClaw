defmodule AlexClaw.Workflows.EveryHeaderSecretTest do
  @moduledoc """
  Every header value in a step is a secret, whatever the header's name (S9
  fix review, M1 ruling). A name says nothing reliable about what a value
  is: `X-Signature`, `X-Pass` or a custom header can carry a credential, so
  no name is guessed. An LLM provider's headers already were (0.4.0 S7).

  - A step's saved config holds a reference for each header; the values are
    in OpenBao, bound to the step's host.
  - At run time each header is attached at send, in its slot.
  - The upgrade moves every header of a 0.3.x step, sealed or not: none is
    written back in the clear, none is parked and emptied.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Config.SecretUpgrade
  alias AlexClaw.{Secrets, Workflows}
  alias AlexClaw.Skills.CircuitBreaker
  alias AlexClaw.Workflows.Executor
  alias AlexClawTest.Legacy
  alias Ecto.Adapters.SQL.Sandbox

  @headers %{
    "Accept" => "application/json",
    "X-Signature" => "sig-value-#{System.unique_integer([:positive])}"
  }

  setup do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    CircuitBreaker.reset("api_request")

    {:ok, wf} =
      Workflows.create_workflow(%{name: "headers #{System.unique_integer()}", enabled: true})

    %{wf: wf}
  end

  defp raw_config(id) do
    %{rows: [[raw]]} = Repo.query!("SELECT config::text FROM workflow_steps WHERE id = $1", [id])
    raw
  end

  defp config(id) do
    %{rows: [[config]]} = Repo.query!("SELECT config FROM workflow_steps WHERE id = $1", [id])
    config
  end

  test "a saved step keeps a reference for every header", %{wf: wf} do
    {:ok, step} =
      Workflows.add_step(wf, %{
        name: "Call",
        skill: "api_request",
        config: %{"url" => "https://api.example.com/x", "headers" => @headers}
      })

    raw = raw_config(step.id)
    refute raw =~ "application/json"
    refute raw =~ @headers["X-Signature"]

    for {header, value} <- @headers do
      assert %{"secret" => name} = config(step.id)["headers"][header]
      assert Secrets.value_matches?(name, value)
      assert Secrets.get(name).binding == ["host:api.example.com"]
    end
  end

  test "every header is sent, attached at send", %{wf: wf} do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.expect_once(bypass, "GET", "/x", fn conn ->
      send(test_pid, {:headers, conn.req_headers})
      Plug.Conn.resp(conn, 200, "ok")
    end)

    {:ok, _step} =
      Workflows.add_step(wf, %{
        name: "Call",
        skill: "api_request",
        config: %{"url" => "http://localhost:#{bypass.port}/x", "headers" => @headers}
      })

    assert {:ok, _run} = Executor.run(wf.id)
    assert_receive {:headers, headers}
    assert {"accept", "application/json"} in headers
    assert {"x-signature", @headers["X-Signature"]} in headers
  end

  describe "the upgrade" do
    setup do
      Legacy.clear_declared_secrets()
      :ok
    end

    test "moves every header of a 0.3.x step, whatever its name", %{wf: wf} do
      id =
        Legacy.insert_step(wf.id, "api_request", %{
          "url" => "https://api.example.com/x",
          "headers" => %{"X-Password" => "hunter2-legacy", "X-Signature" => "sig-legacy"}
        })

      assert {:ok, _report} = SecretUpgrade.run()

      refute raw_config(id) =~ "enc:"
      refute raw_config(id) =~ "sig-legacy"

      headers = config(id)["headers"]
      assert %{"secret" => signature} = headers["X-Signature"]
      assert Secrets.value_matches?(signature, "sig-legacy")
      assert %{"secret" => password} = headers["X-Password"]
      assert Secrets.value_matches?(password, "hunter2-legacy")
    end

    test "moves a plain header saved beside a reference before every header was a secret", %{
      wf: wf
    } do
      {:ok, step} =
        Workflows.add_step(wf, %{
          name: "Call",
          skill: "api_request",
          config: %{
            "url" => "https://api.example.com/x",
            "headers" => %{"Authorization" => "Bearer kept"}
          }
        })

      # As a step saved before this ruling holds it: a reference and a plain value.
      reference = config(step.id)["headers"]["Authorization"]

      Repo.query!("UPDATE workflow_steps SET config = $2 WHERE id = $1", [
        step.id,
        %{
          "url" => "https://api.example.com/x",
          "headers" => %{"Authorization" => reference, "Accept" => "application/json"}
        }
      ])

      assert {:ok, _report} = SecretUpgrade.run()

      headers = config(step.id)["headers"]
      assert headers["Authorization"] == reference
      assert %{"secret" => accept} = headers["Accept"]
      assert Secrets.value_matches?(accept, "application/json")
    end

    test "moves a step whose headers include no credential-named one, emptying none", %{wf: wf} do
      id =
        Legacy.insert_step(wf.id, "api_request", %{
          "url" => "https://api.example.com/x",
          "headers" => %{"Accept" => "application/json", "Content-Type" => "text/plain"}
        })

      assert {:ok, _report} = SecretUpgrade.run()

      headers = config(id)["headers"]

      for {header, value} <- [{"Accept", "application/json"}, {"Content-Type", "text/plain"}] do
        assert %{"secret" => name} = headers[header], "#{header} was emptied or left as it was"
        assert Secrets.value_matches?(name, value)
      end
    end
  end
end
