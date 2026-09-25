defmodule AlexClaw.ConfigSecretSettingsTest do
  @moduledoc """
  Secret settings live in OpenBao, not in the settings table
  (reports/V040_SECURITY_DESIGN.md §5, §6; THREAT_MODEL.md P1, P5; 0.4.0 S3).
  The first one moved is the Telegram bot token; every other secret setting
  follows the same pattern.

  - The settings registry DECLARES which keys are secrets, each with its
    binding. `telegram.bot_token` is bound to the host of the Telegram API
    the gateway actually uses (`:telegram_api_base`), so a test pointing the
    gateway at a local stub binds to that host, and production to
    api.telegram.org.
  - Every write of a declared-secret key — `Config.set/3` and
    `Config.persist/3`, which the Config page uses — stores the value in
    OpenBao (as the secret `setting_telegram_bot_token`, bound as declared)
    and leaves no value in the settings table. The routing lives at the one
    point every write goes through, so no path can put a token back in the
    table. Both return `{:ok, %Setting{}}` as for any key; the setting simply
    carries no value. Writing "" keeps the current value.
  - `Config.get/1` on a declared-secret key is refused: code that needs the
    token resolves it, with its destination (`Config.secret/2`, which goes
    through `Secrets.resolve/2`: binding checked, use audited).
  - `Config.secret_set_at/1` tells a form when it was last set — the only
    thing about the value a form may show.
  - The environment no longer seeds it: `TELEGRAM_BOT_TOKEN` in `.env` is
    ignored (one home per value).
  - The gateway sends with the token from OpenBao.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  import Ecto.Query

  alias AlexClaw.{Config, Secrets}
  alias AlexClaw.Gateway.Telegram

  @token "123456:test-token-#{System.unique_integer([:positive])}"

  setup do
    bypass = Bypass.open()
    Application.put_env(:alex_claw, :telegram_api_base, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:alex_claw, :telegram_api_base) end)
    {:ok, bypass: bypass}
  end

  defp set_token(value) do
    {:ok, setting} = Config.set("telegram.bot_token", value, type: "string", category: "telegram")
    setting
  end

  defp refute_in_settings_table(value) do
    %{rows: rows} = Repo.query!("SELECT row_to_json(s)::text FROM settings s")
    refute Enum.any?(rows, fn [json] -> json =~ value end), "the value is in the settings table"
  end

  describe "the declaration" do
    test "telegram.bot_token is declared secret, the chat id is not" do
      assert Config.secret?("telegram.bot_token")
      refute Config.secret?("telegram.chat_id")
    end

    test "its binding is the host of the Telegram API in use" do
      assert Config.secret_binding("telegram.bot_token") == "host:localhost"

      Application.put_env(:alex_claw, :telegram_api_base, "https://api.telegram.org")
      assert Config.secret_binding("telegram.bot_token") == "host:api.telegram.org"
    end
  end

  describe "saving through set/3" do
    test "the value goes to OpenBao; the setting carries none" do
      setting = set_token(@token)

      assert is_nil(setting.value) or setting.value == ""

      assert {:ok, %{"value" => @token}} =
               AlexClaw.Vault.read("alexclaw/secrets/setting_telegram_bot_token")

      refute_in_settings_table(@token)
    end

    test "it is catalogued, bound as declared" do
      set_token(@token)

      secret = Secrets.get("setting_telegram_bot_token")
      assert secret
      assert secret.binding == ["host:localhost"]
    end

    test "an empty value keeps the current one" do
      set_token(@token)
      set_token("")

      assert {:ok, @token} = Config.secret("telegram.bot_token", for: "host:localhost")
    end

    test "a new value rotates it, and the set date moves" do
      set_token(@token)
      first = Config.secret_set_at("telegram.bot_token")
      assert %DateTime{} = first

      Process.sleep(1_100)
      set_token("999:rotated")

      assert {:ok, "999:rotated"} = Config.secret("telegram.bot_token", for: "host:localhost")
      assert DateTime.compare(Config.secret_set_at("telegram.bot_token"), first) == :gt
    end

    test "never set: no date" do
      assert is_nil(Config.secret_set_at("telegram.bot_token"))
    end
  end

  # The Config page saves through persist/3, not set/3. Routing only at set/3
  # would let a page save put the token back into the settings table.
  describe "saving through persist/3 — the Config page's path" do
    test "routes the same way: OpenBao, nothing in the table" do
      {:ok, _setting} =
        Config.persist("telegram.bot_token", @token, type: "string", category: "telegram")

      assert {:ok, %{"value" => @token}} =
               AlexClaw.Vault.read("alexclaw/secrets/setting_telegram_bot_token")

      refute_in_settings_table(@token)
    end
  end

  describe "reading" do
    test "Config.get/1 refuses a declared-secret key, saying how to get it" do
      set_token(@token)
      assert_raise ArgumentError, ~r/secret/i, fn -> Config.get("telegram.bot_token") end
    end

    test "the value is resolved for its bound destination only" do
      set_token(@token)

      assert {:ok, @token} = Config.secret("telegram.bot_token", for: "host:localhost")
      assert {:error, :not_bound} = Config.secret("telegram.bot_token", for: "host:evil.example")
    end

    # The ETS cache is public (inventory #13): a secret must not be in it.
    test "the value is not in the settings cache" do
      set_token(@token)
      refute inspect(:ets.tab2list(:alexclaw_config)) =~ @token
    end
  end

  describe "the environment no longer seeds it" do
    test "TELEGRAM_BOT_TOKEN in the environment is ignored" do
      System.put_env("TELEGRAM_BOT_TOKEN", "555:from-env")
      on_exit(fn -> System.delete_env("TELEGRAM_BOT_TOKEN") end)

      AlexClaw.Config.Seeder.seed()

      assert {:error, reason} = Config.secret("telegram.bot_token", for: "host:localhost")
      assert reason in [:unknown_secret, :no_value]
    end
  end

  # Empty means "keep", so removing a secret setting is its own action.
  describe "clearing" do
    test "Config.clear/1 removes the secret from OpenBao and its date" do
      set_token(@token)

      :ok = Config.clear("telegram.bot_token")

      assert {:error, :not_found} =
               AlexClaw.Vault.read("alexclaw/secrets/setting_telegram_bot_token")

      assert is_nil(Config.secret_set_at("telegram.bot_token"))
      assert {:error, reason} = Config.secret("telegram.bot_token", for: "host:localhost")
      assert reason in [:unknown_secret, :no_value]
    end
  end

  describe "the gateway" do
    test "sends with the token from OpenBao", %{bypass: bypass} do
      set_token(@token)
      Config.set("telegram.chat_id", "4242", type: "string", category: "telegram")
      Config.set("telegram.enabled", "true", type: "boolean", category: "telegram")

      test_pid = self()

      # A real token contains ":", which Bypass would read as a route
      # parameter; match any bot path and check the token in it instead.
      Bypass.stub(bypass, "POST", "/:bot/sendMessage", fn conn ->
        send(test_pid, {:sent_on, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"ok":true,"result":{"message_id":1}}))
      end)

      assert :ok = Telegram.deliver("4242", "hello", [])
      assert_received {:sent_on, path}
      assert path == "/bot#{@token}/sendMessage"
    end

    # A long-lived consumer resolves once, keeps the value in its own
    # process, and resolves again only when the secret is rotated or the
    # remote says it is no longer valid — not on every poll.
    test "resolves once, not on every send; picks up a rotation", %{bypass: bypass} do
      set_token(@token)
      Config.set("telegram.chat_id", "4242", type: "string", category: "telegram")
      Config.set("telegram.enabled", "true", type: "boolean", category: "telegram")
      test_pid = self()

      Bypass.stub(bypass, "POST", "/:bot/sendMessage", fn conn ->
        send(test_pid, {:sent_on, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"ok":true,"result":{"message_id":1}}))
      end)

      resolves = fn ->
        Repo.aggregate(
          from(e in AlexClaw.Auth.AuditEntry,
            where: e.decision == "allow" and like(e.reason, "%setting_telegram_bot_token%")
          ),
          :count
        )
      end

      before = resolves.()
      for _ <- 1..5, do: :ok = Telegram.deliver("4242", "hello", [])
      assert resolves.() - before <= 1, "the token was resolved on every send"

      set_token("999:rotated")
      :ok = Telegram.deliver("4242", "after rotation", [])

      paths = for _ <- 1..6, do: receive(do: ({:sent_on, p} -> p), after: (1_000 -> nil))
      assert List.last(paths) == "/bot999:rotated/sendMessage", "the rotation was not picked up"
    end
  end
end
