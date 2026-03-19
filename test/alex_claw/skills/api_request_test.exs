defmodule AlexClaw.Skills.ApiRequestTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Skills.ApiRequest

  describe "run/1" do
    test "returns error when no URL provided" do
      assert {:error, :no_url} = ApiRequest.run(%{config: %{"method" => "GET"}})
    end

    test "returns error for invalid method" do
      assert {:error, {:invalid_method, "TRACE"}} =
        ApiRequest.run(%{config: %{"method" => "TRACE", "url" => "http://example.com"}})
    end

    test "interpolates {input} in URL" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api/AAPL", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"ticker": "AAPL"}))
      end)

      result = ApiRequest.run(%{
        config: %{"method" => "GET", "url" => "http://localhost:#{bypass.port}/api/{input}"},
        input: "AAPL"
      })

      assert {:ok, body, _branch} = result
      assert body =~ "AAPL"
    end

    test "interpolates {input_encoded} in URL with URI encoding" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        query = conn.query_string
        assert query =~ "q=hello%20world"
        Plug.Conn.resp(conn, 200, "ok")
      end)

      result = ApiRequest.run(%{
        config: %{"method" => "GET", "url" => "http://localhost:#{bypass.port}/search?q={input_encoded}"},
        input: "hello world"
      })

      assert {:ok, "ok", _branch} = result
    end

    test "handles GET request" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/data", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"status": "ok"}))
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
        config: %{"method" => "GET", "url" => "http://localhost:#{bypass.port}/data"}
      })
    end

    test "handles POST request with JSON body" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/submit", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"key" => "value"}
        Plug.Conn.resp(conn, 200, ~s({"received": true}))
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
        config: %{
          "method" => "POST",
          "url" => "http://localhost:#{bypass.port}/submit",
          "body" => ~s({"key": "value"})
        }
      })
    end

    test "returns error for non-2xx status" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/fail", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      assert {:ok, "not found", :on_4xx} = ApiRequest.run(%{
        config: %{"method" => "GET", "url" => "http://localhost:#{bypass.port}/fail"}
      })
    end

    test "passes custom headers" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/auth", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "x-api-key")
        assert auth == ["secret123"]
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, "ok", _branch} = ApiRequest.run(%{
        config: %{
          "method" => "GET",
          "url" => "http://localhost:#{bypass.port}/auth",
          "headers" => %{"x-api-key" => "secret123"}
        }
      })
    end

    test "defaults to GET method" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/default", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
        config: %{"url" => "http://localhost:#{bypass.port}/default"}
      })
    end
  end
end
