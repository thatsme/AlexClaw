defmodule AlexClaw.Database.EncryptCredentialsTest do
  @moduledoc """
  The boot step that brings stored credentials to rest encrypted: plain text
  written before 0.3.35 is encrypted once, what is encrypted is only checked,
  a value that does not decrypt stops the boot, and a provider holding a copy
  of its setting's key gives the copy up.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config.Crypto
  alias AlexClaw.Database.EncryptCredentials
  alias AlexClaw.LLM.{Client, Provider}
  alias AlexClaw.Workflows
  alias AlexClaw.Workflows.WorkflowStep

  # Rows as a release before 0.3.35 left them: written without the schema.
  defp plain_provider(type, api_key, headers \\ %{}) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO llm_providers (name, type, tier, model, api_key, headers, enabled, priority, inserted_at, updated_at) " <>
          "VALUES ($1, $2, 'light', 'm', $3, $4, true, 50, now(), now()) RETURNING id",
        ["plain-#{System.unique_integer([:positive])}", type, api_key, headers]
      )

    id
  end

  defp plain_step(config) do
    {:ok, workflow} =
      Workflows.create_workflow(%{name: "plain-#{System.unique_integer([:positive])}"})

    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO workflow_steps (workflow_id, position, name, skill, config, inserted_at, updated_at) " <>
          "VALUES ($1, 1, 's', 'telegram_notify', $2, now(), now()) RETURNING id",
        [workflow.id, config]
      )

    id
  end

  defp stored(table, column, id) do
    %{rows: [[value]]} = Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [id])
    value
  end

  defp foreign(plaintext) do
    {:ok, c} =
      Crypto.encrypt_with(Crypto.key_for(String.duplicate("another-key-base", 4)), plaintext)

    c
  end

  test "encrypts plain-text provider keys, header values and step secrets" do
    p = plain_provider("openai_compatible", "sk-plain", %{"x-api-key" => "hdr-plain"})
    s = plain_step(%{"bot_token" => "123:plain", "chat_id" => "7"})

    assert {:ok, %{encrypted: 2}} = EncryptCredentials.run()

    assert Crypto.encrypted?(stored("llm_providers", "api_key", p))
    assert Crypto.encrypted?(stored("llm_providers", "headers", p)["x-api-key"])
    assert Crypto.encrypted?(stored("workflow_steps", "config", s)["bot_token"])
    assert stored("workflow_steps", "config", s)["chat_id"] == "7"

    assert Repo.get!(Provider, p).api_key == "sk-plain"
    assert Repo.get!(WorkflowStep, s).config["bot_token"] == "123:plain"
  end

  test "a second run changes nothing" do
    p = plain_provider("openai_compatible", "sk-plain")
    {:ok, _} = EncryptCredentials.run()
    first = stored("llm_providers", "api_key", p)

    assert {:ok, %{encrypted: 0, copies: 0}} = EncryptCredentials.run()
    assert stored("llm_providers", "api_key", p) == first
  end

  test "leaves nil, empty and absent values as they are" do
    none = plain_provider("openai_compatible", nil)
    empty = plain_provider("openai_compatible", "")
    s = plain_step(%{"bot_token" => "", "chat_id" => "1"})

    assert {:ok, %{encrypted: 0}} = EncryptCredentials.run()
    assert stored("llm_providers", "api_key", none) == nil
    assert stored("llm_providers", "api_key", empty) == ""
    assert stored("workflow_steps", "config", s)["bot_token"] == ""
  end

  test "a value encrypted under another key stops it, naming the row and never the value" do
    # Written first, so it is encrypted before the bad row is reached: the
    # whole run is one transaction, and none of it may stay.
    plain = plain_provider("openai_compatible", "sk-plain")
    bad = plain_provider("openai_compatible", foreign("sk-foreign"))

    error = assert_raise RuntimeError, fn -> EncryptCredentials.run() end
    assert error.message =~ "llm_providers #{bad} api_key"
    assert error.message =~ "Restore the previous SECRET_KEY_BASE"
    assert error.message =~ "re-key procedure"
    refute error.message =~ "sk-foreign"
    refute Crypto.encrypted?(stored("llm_providers", "api_key", plain)), "nothing was written"
  end

  test "a step secret encrypted under another key stops it" do
    s = plain_step(%{"bot_token" => foreign("t")})

    error = assert_raise RuntimeError, fn -> EncryptCredentials.run() end
    assert error.message =~ "workflow_steps #{s} config.bot_token"
  end

  # The same rule as for credentials: a setting encrypted under another key is
  # a changed SECRET_KEY_BASE, not something to start without.
  test "a setting encrypted under another key stops it, and every bad row is named at once" do
    {:ok, _} = AlexClaw.Config.set("boot.good", "fine", sensitive: true)

    for key <- ["auth.totp.secret", "boot.lost"] do
      Repo.query!(
        "INSERT INTO settings (key, value, type, category, sensitive, inserted_at, updated_at) " <>
          "VALUES ($1, $2, 'string', 'test', true, now(), now()) " <>
          "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        [key, foreign("lost-value")]
      )
    end

    bad = plain_provider("openai_compatible", foreign("sk-foreign"))

    error = assert_raise RuntimeError, fn -> EncryptCredentials.run() end
    assert error.message =~ "settings auth.totp.secret"
    assert error.message =~ "settings boot.lost"
    assert error.message =~ "llm_providers #{bad} api_key"
    refute error.message =~ "boot.good"
    refute error.message =~ "lost-value"
  end

  test "with every value decrypting, it starts and changes nothing" do
    {:ok, _} = AlexClaw.Config.set("boot.good", "fine", sensitive: true)
    %{rows: [[before]]} = Repo.query!("SELECT value FROM settings WHERE key = 'boot.good'")

    assert {:ok, _} = EncryptCredentials.run()
    assert {:ok, _} = EncryptCredentials.run()

    %{rows: [[after_runs]]} = Repo.query!("SELECT value FROM settings WHERE key = 'boot.good'")
    assert after_runs == before
    assert Crypto.decrypt(after_runs) == {:ok, "fine"}
  end

  describe "a provider seeded with a copy of its setting's key" do
    setup do
      {:ok, _} = AlexClaw.Config.set("llm.gemini_api_key", "gm-from-setting", sensitive: true)
      :ok
    end

    test "gives up the copy, and the client reads the setting" do
      copy = plain_provider("gemini", "gm-from-setting")

      assert {:ok, %{copies: 1}} = EncryptCredentials.run()
      assert stored("llm_providers", "api_key", copy) == nil
      assert Client.resolve_api_key(Repo.get!(Provider, copy)) == "gm-from-setting"
    end

    test "keeps a key of its own that differs from the setting" do
      own = plain_provider("gemini", "gm-its-own")

      assert {:ok, %{copies: 0}} = EncryptCredentials.run()
      assert Repo.get!(Provider, own).api_key == "gm-its-own"
    end
  end
end
