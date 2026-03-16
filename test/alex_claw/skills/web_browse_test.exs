defmodule AlexClaw.Skills.WebBrowseTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Skills.WebBrowse

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(AlexClaw.Repo, {:shared, self()})
    :ok
  end

  describe "run/1" do
    test "returns error with no url" do
      assert {:error, :no_url} = WebBrowse.run(%{config: %{}, input: nil})
    end

    test "returns error with empty url" do
      assert {:error, :no_url} = WebBrowse.run(%{config: %{"url" => ""}, input: ""})
    end

    test "fetches page via bypass" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/page", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(200, """
        <html>
          <head><title>Test</title></head>
          <body><p>Hello world content here</p></body>
        </html>
        """)
      end)

      result = WebBrowse.run(%{
        config: %{"url" => "http://localhost:#{bypass.port}/page"},
        input: nil
      })

      assert match?({:ok, _}, result) or match?({:error, {:summarize_failed, _}}, result)
    end

    test "uses config url over input" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/configured", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(200, "<html><body>configured page</body></html>")
      end)

      result = WebBrowse.run(%{
        config: %{"url" => "http://localhost:#{bypass.port}/configured"},
        input: "http://ignored.example.com"
      })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles HTTP errors" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/notfound", fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      result = WebBrowse.run(%{
        config: %{"url" => "http://localhost:#{bypass.port}/notfound"},
        input: nil
      })

      assert {:error, {:http, 404}} = result
    end

    test "passes question to QA mode" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/qa", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(200, "<html><body>The answer is 42</body></html>")
      end)

      result = WebBrowse.run(%{
        config: %{
          "url" => "http://localhost:#{bypass.port}/qa",
          "question" => "What is the answer?"
        },
        input: nil
      })

      assert match?({:ok, _}, result) or match?({:error, {:qa_failed, _}}, result)
    end
  end
end
