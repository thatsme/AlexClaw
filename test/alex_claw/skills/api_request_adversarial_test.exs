defmodule AlexClaw.Skills.ApiRequestAdversarialTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Skills.ApiRequest

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  describe "input validation" do
    test "rejects missing url" do
      assert {:error, :no_url} = ApiRequest.run(%{config: %{}, input: nil})
    end

    test "rejects empty url" do
      assert {:error, :no_url} = ApiRequest.run(%{config: %{"url" => ""}, input: nil})
    end

    test "rejects invalid HTTP method" do
      assert {:error, {:invalid_method, "TRACE"}} =
               ApiRequest.run(%{config: %{"url" => "http://localhost", "method" => "TRACE"}})
    end

    test "rejects OPTIONS method" do
      assert {:error, {:invalid_method, "OPTIONS"}} =
               ApiRequest.run(%{config: %{"url" => "http://localhost", "method" => "OPTIONS"}})
    end

    test "uppercases method" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:#{bypass.port}/test", "method" => "get"}
             })
    end
  end

  describe "input interpolation edge cases" do
    test "handles nil input without crashing" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:#{bypass.port}/test"},
               input: nil
             })
    end

    test "handles map input — serialized to JSON" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/data", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:#{bypass.port}/data"},
               input: %{"key" => "value"}
             })
    end

    test "handles integer input" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/data", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:#{bypass.port}/data"},
               input: 42
             })
    end

    test "URL-encodes special chars in {input_encoded}" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/search", fn conn ->
        query = conn.query_string
        assert query =~ "%20" or query =~ "+"
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:#{bypass.port}/search?q={input_encoded}"},
               input: "hello world & more"
             })
    end

    test "handles input with shell metacharacters" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:#{bypass.port}/test"},
               input: "; rm -rf / && echo pwned"
             })
    end

    test "handles input with newlines and control chars" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/data", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
               config: %{
                 "url" => "http://localhost:#{bypass.port}/data",
                 "method" => "POST",
                 "body" => "{input}"
               },
               input: "line1\nline2\r\n\ttab\0null"
             })
    end
  end

  describe "response handling" do
    test "handles empty response body" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/empty", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, "", _branch} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:#{bypass.port}/empty"}
             })
    end

    test "handles very large response body" do
      bypass = Bypass.open()
      huge = String.duplicate("x", 100_000)

      Bypass.expect(bypass, "GET", "/huge", fn conn ->
        Plug.Conn.resp(conn, 200, huge)
      end)

      assert {:ok, body, _branch} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:#{bypass.port}/huge"}
             })

      assert String.length(body) == 100_000
    end

    test "handles JSON response with nested structure" do
      bypass = Bypass.open()

      json = Jason.encode!(%{
        data: %{nested: %{deep: [1, 2, 3]}},
        meta: %{page: 1}
      })

      Bypass.expect(bypass, "GET", "/json", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, json)
      end)

      assert {:ok, body, _branch} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:#{bypass.port}/json"}
             })

      assert is_binary(body)
    end

    test "handles server error 500" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/error", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      assert {:ok, "Internal Server Error", :on_5xx} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:#{bypass.port}/error"}
             })
    end

    test "handles connection refused" do
      assert {:error, _reason} = ApiRequest.run(%{
               config: %{"url" => "http://localhost:1/unreachable"}
             })
    end

    test "handles malformed headers config" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/test", fn conn ->
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
               config: %{
                 "url" => "http://localhost:#{bypass.port}/test",
                 "headers" => "not-a-map"
               }
             })
    end

    test "handles malformed body as plain text" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/data", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "not json {"
        Plug.Conn.resp(conn, 200, "ok")
      end)

      assert {:ok, _, _branch} = ApiRequest.run(%{
               config: %{
                 "url" => "http://localhost:#{bypass.port}/data",
                 "method" => "POST",
                 "body" => "not json {"
               }
             })
    end
  end

  describe "missing config keys" do
    test "handles completely empty args" do
      assert {:error, :no_url} = ApiRequest.run(%{})
    end

    test "handles nil config" do
      assert {:error, :no_url} = ApiRequest.run(%{config: nil})
    end
  end
end
