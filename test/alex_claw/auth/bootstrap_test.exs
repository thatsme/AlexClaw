defmodule AlexClaw.Auth.BootstrapTest do
  @moduledoc """
  A fresh install, configured only by environment variables, can reach 2FA.

  This is the path that makes a strict control plane usable: nothing can be
  changed from the admin UI until a second factor exists, so the route to that
  second factor cannot itself run through the admin UI. It runs through a
  gateway that the environment alone makes reachable.

  The walk is deliberately end to end — bare settings, `/setup 2fa`,
  `/confirm 2fa <code>`, then an elevation challenge that actually arrives.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Elevation, Gate, TOTP}
  alias AlexClaw.Gateway.Credentials

  # What a first boot looks like when the environment carried the values: the
  # seeder writes them into empty rows it finds, and a blank row falls back.
  defp bare_install do
    for key <- ~w(telegram.chat_id telegram.bot_token discord.channel_id discord.bot_token) do
      category = key |> String.split(".") |> List.first()
      AlexClaw.Config.set(key, "", type: "string", category: category)
    end

    AlexClaw.Config.set("auth.totp.enabled", "false", type: "boolean", category: "auth")
    AlexClaw.Config.delete("auth.totp.secret")
  end

  # Unique per test: the challenge table is owned by a supervised process and
  # outlives any one of them, so a literal id lets one test's challenge answer
  # another's assertion.
  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  describe "an instance configured only by TELEGRAM_* variables" do
    test "is reachable before anything has been written to the database" do
      bare_install()
      chat = unique("boot-chat")

      with_env([{"TELEGRAM_CHAT_ID", chat}, {"TELEGRAM_BOT_TOKEN", "boot-token"}], fn ->
        assert Credentials.notify_targets() == [chat]
        assert Credentials.telegram_token() == "boot-token"
        assert Credentials.reachable?()
      end)
    end

    test "walks from no second factor to an elevation that can be challenged" do
      bare_install()
      chat = unique("boot-chat")

      with_env([{"TELEGRAM_CHAT_ID", chat}, {"TELEGRAM_BOT_TOKEN", "boot-token"}], fn ->
        # 1. The control plane is closed: nothing to elevate with.
        refute Elevation.configured?()
        assert Gate.request(%{type: :elevate, sid: "sid"}, "Unlock") == :no_2fa

        # 2. /setup 2fa on the gateway — the one route that does not need the UI.
        {:ok, %{secret: secret}} = TOTP.setup()
        :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

        # 3. A second factor now exists, and the prompt has somewhere to go.
        assert Elevation.configured?()
        assert Gate.request(%{type: :elevate, sid: "sid"}, "Unlock") == :challenged
        assert TOTP.pending_challenge?(chat)
      end)
    end

    test "answering the code elevates the session that asked" do
      bare_install()
      chat = unique("boot-chat")

      with_env([{"TELEGRAM_CHAT_ID", chat}, {"TELEGRAM_BOT_TOKEN", "boot-token"}], fn ->
        {:ok, %{secret: secret}} = TOTP.setup()
        :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

        sid = Elevation.new_sid()
        :challenged = Gate.request(%{type: :elevate, sid: sid}, "Unlock")

        assert {:ok, action} = TOTP.resolve_challenge(chat, code_for(secret))
        assert action.type == :elevate
        assert action.sid == sid
      end)
    end
  end

  describe "an instance configured only by DISCORD_* variables" do
    test "is reachable, and can be challenged" do
      bare_install()

      channel = unique("boot-channel")

      with_env(
        [{"DISCORD_CHANNEL_ID", channel}, {"DISCORD_BOT_TOKEN", "boot-token"}],
        fn ->
          {:ok, %{secret: secret}} = TOTP.setup()
          :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

          assert Credentials.discord_token() == "boot-token"
          assert Gate.request(%{type: :elevate, sid: "sid"}, "Unlock") == :challenged
          assert TOTP.pending_challenge?(channel)
        end
      )
    end

    # Once an operator has set the channel in the UI, that is the answer —
    # the variable is a bootstrap, not an override.
    test "stops using the variable once the setting holds a value" do
      bare_install()
      chosen = unique("chosen-in-ui")
      from_env = unique("boot-channel")

      AlexClaw.Config.set("discord.channel_id", chosen,
        type: "string",
        category: "discord"
      )

      with_env([{"DISCORD_CHANNEL_ID", from_env}], fn ->
        {:ok, %{secret: secret}} = TOTP.setup()
        :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

        assert Gate.request(%{type: :elevate, sid: "sid"}, "Unlock") == :challenged
        assert TOTP.pending_challenge?(chosen)
        refute TOTP.pending_challenge?(from_env)
      end)
    end
  end

  describe "an instance with no gateway at all" do
    test "cannot be elevated, and says so by refusing" do
      bare_install()

      with_env([{"TELEGRAM_CHAT_ID", ""}, {"DISCORD_CHANNEL_ID", ""}], fn ->
        {:ok, %{secret: secret}} = TOTP.setup()
        :ok = TOTP.confirm_setup(NimbleTOTP.verification_code(secret))

        # 2FA exists, but there is nowhere to send the prompt: still closed.
        assert Elevation.configured?()
        assert Gate.request(%{type: :elevate, sid: "sid"}, "Unlock") == :no_2fa
      end)
    end
  end

  defp code_for(secret), do: NimbleTOTP.verification_code(secret)
end
