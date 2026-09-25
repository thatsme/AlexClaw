defmodule AlexClaw.Config.SeederTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config
  alias AlexClaw.Config.{Seeder, Setting}

  describe "seed/0" do
    test "creates expected default settings" do
      assert :ok = Seeder.seed()

      # Seeding writes rows; it does not warm the cache, and for a key that is
      # already present it now does nothing at all. Config.init/0 is what loads
      # the rows into ETS, and Loader calls it on either side of the seed.
      Config.init()

      # Spot-check key defaults across categories
      assert Config.get("telegram.enabled") != nil
      assert Config.get("discord.enabled") != nil
      assert Config.get("identity.name") != nil
      assert Config.get("shell.enabled") != nil
      assert Config.get("auth.rate_limit.max_attempts") != nil
      assert Config.get("prompts.rss.interests") != nil
      assert Config.get("backup.enabled") != nil
    end

    test "is idempotent — calling twice does not create duplicates" do
      Seeder.seed()
      count_before = Repo.aggregate(Setting, :count)

      Seeder.seed()
      count_after = Repo.aggregate(Setting, :count)

      assert count_before == count_after
    end

    test "does not overwrite existing user-configured values" do
      Config.set("identity.name", "MyCustomName", type: "string", category: "identity")

      Seeder.seed()

      assert Config.get("identity.name") == "MyCustomName"
    end

    test "marks sensitive settings correctly" do
      Seeder.seed()

      bot_token = Repo.get_by(Setting, key: "telegram.bot_token")
      assert bot_token.sensitive == true

      gemini_key = Repo.get_by(Setting, key: "llm.gemini_api_key")
      assert gemini_key.sensitive == true

      # Non-sensitive setting
      enabled = Repo.get_by(Setting, key: "telegram.enabled")
      assert enabled.sensitive == false
    end

    test "updates sensitive flag on existing non-sensitive setting" do
      # Pre-create a setting with sensitive=false that should be sensitive
      Config.set("telegram.bot_token", "test_token", type: "string", category: "telegram")

      record = Repo.get_by(Setting, key: "telegram.bot_token")
      record |> Ecto.Changeset.change(%{sensitive: false}) |> Repo.update!()

      Seeder.seed()

      updated = Repo.get_by(Setting, key: "telegram.bot_token")
      assert updated.sensitive == true
    end
  end

  describe "env/1" do
    test "returns environment variable value when set" do
      System.put_env("OLLAMA_HOST", "http://ollama.test:11434")
      on_exit(fn -> System.delete_env("OLLAMA_HOST") end)

      assert Seeder.env("llm.ollama_host") == "http://ollama.test:11434"
    end

    # One home per value (0.4.0): a declared-secret setting lives in OpenBao,
    # set through the Config page; the environment never seeds it, even when
    # the old variable is still around.
    test "never reads a declared-secret key from the environment" do
      System.put_env("TELEGRAM_BOT_TOKEN", "test_env_token")
      on_exit(fn -> System.delete_env("TELEGRAM_BOT_TOKEN") end)

      assert Seeder.env("telegram.bot_token") == ""
    end

    test "returns default when environment variable is not set" do
      System.delete_env("TELEGRAM_BOT_TOKEN")

      assert Seeder.env("telegram.bot_token") == ""
    end

    test "returns empty string for unmapped key" do
      assert Seeder.env("nonexistent.key") == ""
    end

    test "returns default for Ollama host when env not set" do
      System.delete_env("OLLAMA_HOST")

      assert Seeder.env("llm.ollama_host") == "http://localhost:11434"
    end
  end
end
