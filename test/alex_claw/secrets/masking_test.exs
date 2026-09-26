defmodule AlexClaw.Secrets.MaskingTest do
  @moduledoc """
  A value resolved from OpenBao never travels on in the clear (S8 H1, H8;
  THREAT_MODEL P1; V040_SECURITY_DESIGN.md §6 "Values that come back in
  outputs").

  Every value `AlexClaw.Secrets` hands out is remembered, in memory only, and
  masked as `[secret]` wherever it could travel next: a run's step results,
  result, error and outcomes (and so exports and MCP, which read them), the
  gateways, audit rows and log lines — including an error that quotes it, as
  an HTTP client's does for a malformed header. A value with surrounding
  whitespace or a control character is refused when it is entered: it could
  only fail, and its failure would quote it.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  import ExUnit.CaptureLog
  require Logger

  alias AlexClaw.Auth.{AuditEntry, AuditLog}
  alias AlexClaw.Database.DataExport
  alias AlexClaw.Gateway.Router
  alias AlexClaw.{RecordingGateway, Secrets, Workflows}
  alias AlexClaw.Webhooks.GitHubSecret
  alias AlexClaw.Workflows.{Executor, SkillOutcome, WorkflowRun}
  alias Ecto.Adapters.SQL.Sandbox

  @value "masked-value-#{System.unique_integer([:positive])}"

  defp resolved_value do
    name = "mask_probe_#{System.unique_integer([:positive])}"
    {:ok, _} = Secrets.define(%{name: name, kind: "api_token", binding: ["host:example.com"]})
    :ok = Secrets.put_value(name, @value)
    {:ok, @value} = Secrets.resolve(name, for: "host:example.com")
    @value
  end

  defp export_text do
    ""
    |> DataExport.write(fn data, acc -> [acc, data] end)
    |> IO.iodata_to_binary()
  end

  describe "a value a run's API sends back" do
    setup do
      Sandbox.mode(AlexClaw.Repo, {:shared, self()})
      bypass = Bypass.open()

      {:ok, wf} =
        Workflows.create_workflow(%{name: "mask #{System.unique_integer()}", enabled: true})

      {:ok, _step} =
        Workflows.add_step(wf, %{
          name: "Echo",
          skill: "api_request",
          config: %{
            "url" => "http://localhost:#{bypass.port}/echo",
            "headers" => %{"Authorization" => "Bearer " <> @value}
          }
        })

      %{bypass: bypass, wf: wf}
    end

    test "is masked in the step results, the result, the outcomes and the export", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "/echo", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.resp(conn, 200, "you sent: " <> auth)
      end)

      {:ok, run} = Executor.run(ctx.wf.id)
      run = Repo.get!(WorkflowRun, run.id)
      outcomes = Repo.all(SkillOutcome)

      assert inspect(run.step_results) =~ "[secret]", "the echo did not happen"

      for {what, text} <- [
            {"step results", inspect(run.step_results)},
            {"result", inspect(run.result)},
            {"outcomes", inspect(outcomes)},
            {"export", export_text()}
          ] do
        refute text =~ @value, "the value is in the run's #{what}"
      end
    end

    test "is masked in the run's error when a failure quotes it", ctx do
      Bypass.expect_once(ctx.bypass, "GET", "/echo", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.resp(conn, 401, "refused: " <> auth)
      end)

      {:error, run} = Executor.run(ctx.wf.id)
      run = Repo.get!(WorkflowRun, run.id)

      assert inspect({run.error, run.step_results}) =~ "[secret]", "the failure did not quote it"
      refute inspect({run.error, run.step_results}) =~ @value
    end
  end

  test "a log line that quotes a resolved value is masked" do
    value = resolved_value()

    log =
      capture_log(fn ->
        Logger.error(~s|request failed: {:invalid_header_value, "auth", "#{value}"}|)
      end)

    assert log =~ "[secret]"
    refute log =~ value
  end

  test "a message sent to a gateway is masked" do
    RecordingGateway.install()
    value = resolved_value()

    Router.send_message("step failed: " <> value)

    assert Enum.any?(RecordingGateway.sent(), &(&1 =~ "[secret]"))
    refute Enum.any?(RecordingGateway.sent(), &(&1 =~ value))
  end

  test "an audit row that quotes a resolved value is masked" do
    value = resolved_value()

    AuditLog.log_action_refusal(
      "probe",
      :admin_ui,
      :set_setting,
      "echoed " <> value
    )

    texts = AuditEntry |> Repo.all() |> Enum.map(&inspect/1)
    assert Enum.any?(texts, &(&1 =~ "[secret]"))
    refute Enum.any?(texts, &(&1 =~ value))
  end

  test "a process holding a secret does not show it in its status" do
    Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    name = "setting_github_webhook_secret"

    {:ok, _} =
      AlexClaw.Config.set("github.webhook_secret", @value, type: "string", category: "github")

    assert GitHubSecret.get() == @value, "#{name} was not held"

    refute inspect(:sys.get_status(GitHubSecret)) =~ @value
  end

  describe "a value that could only fail is refused when it is entered" do
    for {what, bad} <- [
          {"a trailing space", "token-value "},
          {"a leading space", " token-value"},
          {"a trailing newline", "token-value\n"},
          {"a control character", "token\u0000value"}
        ] do
      test "with #{what}" do
        name = "malformed_#{System.unique_integer([:positive])}"
        {:ok, _} = Secrets.define(%{name: name, kind: "api_token", binding: ["host:example.com"]})

        assert {:error, :malformed_value} = Secrets.put_value(name, unquote(bad))
      end
    end
  end
end
