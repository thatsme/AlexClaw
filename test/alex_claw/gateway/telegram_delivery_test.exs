defmodule AlexClaw.Gateway.TelegramDeliveryTest do
  @moduledoc """
  telegram_notify reports what Telegram answered (reports/SECOND_ROUND_SEAMS.md
  §1, §3; 0.3.53).

  `Gateway.Telegram.send_html/2` is a cast: the HTTP send happens inside the
  gateway process and its result is discarded, so `telegram_notify` always
  said `:on_delivered`. And it sent through the router's default gateway —
  with Telegram unconfigured and Discord configured, the digest went to
  Discord with a Telegram chat id as the channel, failed there, and was still
  reported delivered.

  Now:
  - `Gateway.Telegram.deliver(chat_id, text, opts)` sends in the caller and
    returns `:ok` or `{:error, reason}`; `send_html/2` stays a cast for
    notices that do not need the answer;
  - the Telegram API base URL is one setting (`:telegram_api_base`, default
    https://api.telegram.org), so a test can point it at Bypass;
  - `telegram_notify` sends through `deliver/3`, to Telegram only, and
    returns `:on_delivered` only when Telegram said ok.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Gateway.Telegram
  alias AlexClaw.Skills.TelegramNotify

  @token "test-token"

  setup do
    bypass = Bypass.open()
    Application.put_env(:alex_claw, :telegram_api_base, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:alex_claw, :telegram_api_base) end)

    insert_setting("telegram.bot_token", @token, type: "string", category: "telegram")
    insert_setting("telegram.chat_id", "4242", type: "string", category: "telegram")
    # Sending needs Telegram enabled, as the send path always has.
    insert_setting("telegram.enabled", "true", type: "boolean", category: "telegram")

    %{bypass: bypass}
  end

  defp telegram_answers(bypass, fun) do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/bot#{@token}/sendMessage", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)
      send(test_pid, {:sent, params})
      {status, reply} = fun.(params)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(reply))
    end)
  end

  defp ok, do: {200, %{"ok" => true, "result" => %{"message_id" => 1}}}

  describe "Telegram.deliver/3" do
    test "returns :ok when Telegram accepts the message", %{bypass: bypass} do
      telegram_answers(bypass, fn _ -> ok() end)

      assert :ok = Telegram.deliver("4242", "hello", [])
      assert_receive {:sent, %{"chat_id" => "4242", "text" => "hello"}}
    end

    test "returns the error when Telegram refuses it", %{bypass: bypass} do
      telegram_answers(bypass, fn _ ->
        {403, %{"ok" => false, "description" => "Forbidden: bot was blocked by the user"}}
      end)

      assert {:error, reason} = Telegram.deliver("4242", "hello", [])
      assert inspect(reason) =~ "blocked"
    end

    test "returns an error when Telegram cannot be reached", %{bypass: bypass} do
      Bypass.down(bypass)
      assert {:error, _} = Telegram.deliver("4242", "hello", [])
    end
  end

  describe "telegram_notify" do
    test "is delivered only when Telegram said ok", %{bypass: bypass} do
      telegram_answers(bypass, fn _ -> ok() end)
      assert {:ok, "hello", :on_delivered} = TelegramNotify.run(%{input: "hello", config: %{}})
    end

    test "a refused send is an error, not delivered", %{bypass: bypass} do
      telegram_answers(bypass, fn _ ->
        {400, %{"ok" => false, "description" => "Bad Request: chat not found"}}
      end)

      result = TelegramNotify.run(%{input: "hello", config: %{}})
      assert {:error, reason} = result
      assert inspect(reason) =~ "chat not found"
    end

    # The existing fallback: when Telegram rejects the HTML, the plain text is
    # sent instead. Delivered means the second attempt was accepted.
    test "HTML refused, plain text accepted: delivered", %{bypass: bypass} do
      telegram_answers(bypass, fn params ->
        if params["parse_mode"] == "HTML",
          do: {400, %{"ok" => false, "description" => "Bad Request: can't parse entities"}},
          else: ok()
      end)

      assert {:ok, _, :on_delivered} = TelegramNotify.run(%{input: "a <b> c", config: %{}})
    end

    test "HTML refused and plain text refused: an error", %{bypass: bypass} do
      telegram_answers(bypass, fn _ -> {400, %{"ok" => false, "description" => "Bad Request"}} end)

      assert {:error, _} = TelegramNotify.run(%{input: "a <b> c", config: %{}})
    end

    test "link_preview: false reaches Telegram", %{bypass: bypass} do
      telegram_answers(bypass, fn _ -> ok() end)
      TelegramNotify.run(%{input: "hello", config: %{"link_preview" => false}})

      assert_receive {:sent, %{"link_preview_options" => %{"is_disabled" => true}}}
    end
  end

  describe "telegram_notify never goes to another gateway" do
    test "with Telegram unconfigured and Discord configured, it fails and Discord gets nothing" do
      insert_setting("telegram.chat_id", "", type: "string", category: "telegram")
      insert_setting("discord.channel_id", "123456789", type: "string", category: "discord")

      Mox.stub(AlexClaw.Gateway.Discord.APIMock, :create_message, fn _channel, _content ->
        flunk("telegram_notify sent to Discord")
      end)

      Application.put_env(:alex_claw, :discord_api, AlexClaw.Gateway.Discord.APIMock)
      on_exit(fn -> Application.delete_env(:alex_claw, :discord_api) end)

      assert {:error, :no_chat_id} = TelegramNotify.run(%{input: "hello", config: %{}})
    end
  end
end
