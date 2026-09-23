defmodule AlexClaw.WebAutomation.LifecycleTest do
  @moduledoc """
  Lifecycle, AlexClaw side (reports/WEB_AUTOMATOR_TARGET.md §3).

  web_automation is a core skill, and SafeExecutor runs core skills with no
  timeout: every entry point was bounded only by Req's 300 s, and a step's
  timeout_ms was ignored. And when AlexClaw gave up, the sidecar kept playing.

  Now the skill owns its deadline:
  - play(config, resources, opts) sends a `play_id` (^[A-Za-z0-9-]{8,64}$)
    and a `deadline_ms`: `opts[:deadline_ms]`, else 120_000; run/1 passes a
    workflow step's `timeout_ms` as the deadline, and it never ends up inside
    the recipe;
  - AlexClaw waits deadline_ms + 5_000 for the answer; past that it returns
    {:error, :timeout} and asks the sidecar to stop that play
    (POST /play/<play_id>/stop), as a second line behind the sidecar's own
    deadline;
  - one play at a time, refused not queued: a second play while one runs is
    {:error, :busy} without a request (AlexClaw.Lock, :web_automation).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.WebAutomation

  @recipe %{"url" => "https://example.com", "steps" => []}
  @success %{"status" => "success", "downloads" => [], "screenshots" => [], "scraped_data" => []}

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

  defp capture_play(bypass, response \\ @success) do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/play", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:play, Jason.decode!(body)})
      json(conn, 200, response)
    end)
  end

  describe "what play/3 sends" do
    test "a play id and the default deadline", %{bypass: bypass} do
      capture_play(bypass)

      assert {:ok, _message, :on_success} = WebAutomation.play(@recipe, [])
      assert_receive {:play, body}
      assert body["play_id"] =~ ~r/^[A-Za-z0-9-]{8,64}$/
      assert body["deadline_ms"] == 120_000
      assert body["config"] == @recipe
    end

    test "every play has its own id", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/play", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:id, Jason.decode!(body)["play_id"]})
        json(conn, 200, @success)
      end)

      WebAutomation.play(@recipe, [])
      WebAutomation.play(@recipe, [])
      assert_receive {:id, first}
      assert_receive {:id, second}
      refute first == second
    end

    test "a workflow step's timeout_ms is the deadline, outside the recipe", %{bypass: bypass} do
      capture_play(bypass)

      assert {:ok, _, _} =
               WebAutomation.run(%{
                 config: Map.put(@recipe, "timeout_ms", 45_000),
                 resources: []
               })

      assert_receive {:play, body}
      assert body["deadline_ms"] == 45_000
      refute Map.has_key?(body["config"], "timeout_ms")
    end
  end

  describe "when the sidecar does not answer in time" do
    test "AlexClaw gives up at deadline + 5 s and stops that play" do
      port = silent_sidecar(self())

      insert_setting("web_automator.host", "http://localhost:#{port}",
        type: "string",
        category: "web_automator"
      )

      started = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = WebAutomation.play(@recipe, [], deadline_ms: 1_000)
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed >= 6_000 and elapsed < 8_000, "gave up after #{elapsed} ms"
      assert_receive {:play_id, play_id}
      assert_receive {:stopped, ^play_id}, 2_000
    end
  end

  describe "one play at a time" do
    test "a second play while one runs is :busy, without a request", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/play", fn conn ->
        Process.sleep(1_500)
        json(conn, 200, @success)
      end)

      first = Task.async(fn -> WebAutomation.play(@recipe, []) end)
      Process.sleep(300)

      assert {:error, :busy} = WebAutomation.play(@recipe, [])
      assert {:ok, _message, :on_success} = Task.await(first, 5_000)
    end

    test "the lock is released after a failure", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/play", fn conn ->
        json(conn, 200, %{"status" => "error", "error" => "boom"})
      end)

      assert {:error, {:automation_failed, "boom", _}} = WebAutomation.play(@recipe, [])
      assert {:error, {:automation_failed, "boom", _}} = WebAutomation.play(@recipe, [])
    end
  end

  # A fake sidecar that takes POST /play and never answers, and answers
  # POST /play/<id>/stop. Bypass cannot play the silent part: when the client
  # gives up while a Bypass handler still runs, Cowboy shuts the handler down
  # and Bypass reports that at teardown as the test's own failure (phase-2
  # item 4 report, reproduced without our code).
  defp silent_sidecar(test_pid) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    server = spawn(fn -> accept_loop(listen, test_pid) end)
    on_exit(fn -> Process.exit(server, :kill) end)
    port
  end

  defp accept_loop(listen, test_pid) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handler = spawn_link(fn -> receive(do: (:go -> serve(socket, test_pid))) end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, :go)
        accept_loop(listen, test_pid)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, test_pid) do
    {:ok, {:http_request, :POST, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0, 5_000)
    length = content_length(socket, 0)
    :ok = :inet.setopts(socket, packet: :raw)
    {:ok, body} = if length > 0, do: :gen_tcp.recv(socket, length, 5_000), else: {:ok, ""}

    case String.split(path, "/") do
      ["", "play"] ->
        send(test_pid, {:play_id, Jason.decode!(body)["play_id"]})
        # Hold the connection open and never answer. Bounded, so the handler
        # cannot outlive the test run by much once its server has gone.
        Process.sleep(15_000)
        :gen_tcp.close(socket)

      ["", "play", play_id, "stop"] ->
        send(test_pid, {:stopped, play_id})
        reply = Jason.encode!(%{"message" => "Stopped"})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
            "content-length: #{byte_size(reply)}\r\nconnection: close\r\n\r\n" <> reply
        )

        :gen_tcp.close(socket)
    end
  end

  defp content_length(socket, length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, :"Content-Length", _, value}} ->
        content_length(socket, String.to_integer(value))

      {:ok, {:http_header, _, _, _, _}} ->
        content_length(socket, length)

      {:ok, :http_eoh} ->
        length
    end
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
