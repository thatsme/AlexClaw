defmodule AlexClawTest.TelegramStub do
  @moduledoc """
  A Telegram that answers, for tests that send through the real delivery path
  (0.3.53: `telegram_notify` sends through `Gateway.Telegram.deliver/3` and
  reports what Telegram answered, so a test needs something to answer).

      setup do
        TelegramStub.accept_all()
      end

      # later
      TelegramStub.sent()   # the texts Telegram received, in order

  Enables Telegram with a token and a chat id, points `:telegram_api_base` at
  a Bypass that accepts every sendMessage, and records each request's text.
  Restores the API base on exit.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  @token "stub-token"
  @agent __MODULE__.Sent

  def accept_all(chat_id \\ "4242") do
    bypass = Bypass.open()
    Application.put_env(:alex_claw, :telegram_api_base, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:alex_claw, :telegram_api_base) end)

    AlexClaw.Config.set("telegram.enabled", "true", type: "boolean", category: "telegram")
    AlexClaw.Config.set("telegram.bot_token", @token, type: "string", category: "telegram")
    AlexClaw.Config.set("telegram.chat_id", chat_id, type: "string", category: "telegram")

    {:ok, _} = Agent.start_link(fn -> [] end, name: @agent)

    # Any bot token: tests that pass a custom token hit /bot<token>/sendMessage.
    Bypass.stub(bypass, "POST", "/:bot/sendMessage", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      text = body |> Jason.decode!() |> Map.get("text")
      Agent.update(@agent, &(&1 ++ [text]))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 1}}))
    end)

    %{telegram: bypass}
  end

  @doc "The texts Telegram received so far, in order."
  def sent, do: Agent.get(@agent, & &1)
end
