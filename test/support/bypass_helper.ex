defmodule AlexClaw.BypassHelper do
  @moduledoc """
  Reusable Bypass helpers for common HTTP mock patterns.
  Imported automatically in DataCase and ConnCase.
  """

  @doc "Mock a GET endpoint returning JSON with 200 status."
  def bypass_json_ok(bypass, path, body) do
    Bypass.expect_once(bypass, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  @doc "Mock a POST endpoint returning JSON with 200 status."
  def bypass_post_json_ok(bypass, path, body) do
    Bypass.expect_once(bypass, "POST", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  @doc "Mock any method on a path returning a JSON error."
  def bypass_json_error(bypass, path, status \\ 500) do
    Bypass.expect_once(bypass, fn conn ->
      if conn.request_path == path do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, Jason.encode!(%{"error" => "mocked_error"}))
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
      end
    end)
  end

  @doc "Mock an OpenAI-compatible /v1/chat/completions endpoint."
  def bypass_llm_response(bypass, text) do
    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{
        "choices" => [%{"message" => %{"content" => text}}]
      }))
    end)
  end

  @doc "Mock a Gemini embedding endpoint."
  def bypass_gemini_embedding(bypass, vector) do
    Bypass.expect_once(bypass, "POST", "/v1beta/models/text-embedding-004:embedContent", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"embedding" => %{"values" => vector}}))
    end)
  end

  @doc "Mock a slow endpoint that responds after `delay_ms` milliseconds."
  def bypass_slow_response(bypass, path, delay_ms) do
    Bypass.expect_once(bypass, fn conn ->
      if conn.request_path == path do
        Process.sleep(delay_ms)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "slow"}))
      else
        Plug.Conn.resp(conn, 404, "")
      end
    end)
  end
end
