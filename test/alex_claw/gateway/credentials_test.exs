defmodule AlexClaw.Gateway.CredentialsTest do
  @moduledoc """
  Where a gateway's token and destination come from, and in what order.

  This is the bootstrap path for a strict control plane: with no second factor
  nothing can be changed from the admin UI, so an instance has to be reachable
  from the environment alone or it cannot be configured at all.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Gateway.Credentials

  defp set(key, value) do
    category = key |> String.split(".") |> List.first()
    AlexClaw.Config.set(key, value, type: "string", category: category)
  end

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

  describe "the database wins when it holds a value" do
    test "a set telegram chat id ignores the environment" do
      set("telegram.chat_id", "from-db")

      with_env([{"TELEGRAM_CHAT_ID", "from-env"}], fn ->
        assert Credentials.telegram_chat_id() == "from-db"
      end)
    end

    test "a set discord channel ignores the environment" do
      set("discord.channel_id", "from-db")

      with_env([{"DISCORD_CHANNEL_ID", "from-env"}], fn ->
        assert Credentials.discord_channel_id() == "from-db"
      end)
    end

    test "a set discord token ignores the environment" do
      set("discord.bot_token", "db-token")

      with_env([{"DISCORD_BOT_TOKEN", "env-token"}], fn ->
        assert Credentials.discord_token() == "db-token"
      end)
    end
  end

  describe "an empty setting falls back to the environment" do
    test "a blank discord channel reads DISCORD_CHANNEL_ID" do
      set("discord.channel_id", "")

      with_env([{"DISCORD_CHANNEL_ID", "from-env"}], fn ->
        assert Credentials.discord_channel_id() == "from-env"
      end)
    end

    test "a blank discord token reads DISCORD_BOT_TOKEN" do
      set("discord.bot_token", "")

      with_env([{"DISCORD_BOT_TOKEN", "env-token"}], fn ->
        assert Credentials.discord_token() == "env-token"
      end)
    end

    # The row exists and is empty on every install seeded before this release,
    # which is the case a seeder-time default would not have covered.
    test "a blank telegram chat id reads TELEGRAM_CHAT_ID" do
      set("telegram.chat_id", "")

      with_env([{"TELEGRAM_CHAT_ID", "from-env"}], fn ->
        assert Credentials.telegram_chat_id() == "from-env"
      end)
    end

    test "whitespace is not a value" do
      set("discord.channel_id", "   ")

      with_env([{"DISCORD_CHANNEL_ID", "from-env"}], fn ->
        assert Credentials.notify_targets() == ["from-env"]
      end)
    end
  end

  describe "with neither" do
    test "there is nothing to notify" do
      set("telegram.chat_id", "")
      set("discord.channel_id", "")

      with_env([{"TELEGRAM_CHAT_ID", ""}, {"DISCORD_CHANNEL_ID", ""}], fn ->
        assert Credentials.notify_targets() == []
        refute Credentials.reachable?()
      end)
    end
  end

  describe "notify_targets/0" do
    test "carries both gateways when both are configured" do
      set("telegram.chat_id", "tg")
      set("discord.channel_id", "dc")

      assert Credentials.notify_targets() == ["tg", "dc"]
      assert Credentials.reachable?()
    end

    test "carries a gateway that exists only in the environment" do
      set("telegram.chat_id", "")
      set("discord.channel_id", "")

      with_env([{"TELEGRAM_CHAT_ID", ""}, {"DISCORD_CHANNEL_ID", "env-only"}], fn ->
        assert Credentials.notify_targets() == ["env-only"]
      end)
    end
  end
end
