defmodule AlexClaw.Config.RekeyTest do
  @moduledoc """
  Rotating SECRET_KEY_BASE moves every encrypted setting — the TOTP secret
  among them — to the new key in one audited transaction, ends every login,
  and refuses, with nothing changed, when the old key is wrong.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AdminSession, AuditEntry, Elevation, Sessions}
  alias AlexClaw.Config.{Crypto, Rekey, Setting}

  @old Application.compile_env!(:alex_claw, [AlexClawWeb.Endpoint, :secret_key_base])
  @new String.duplicate("n", 64)

  defp stored(key), do: Repo.get_by!(Setting, key: key).value

  setup do
    {:ok, _} = AlexClaw.Config.set("rekey.api_token", "s3cret-token", sensitive: true)
    {:ok, _} = AlexClaw.Config.set("auth.totp.secret", "JBSWY3DPEHPK3PXP", sensitive: true)
    {:ok, _} = AlexClaw.Config.set("rekey.plain", "not secret")
    :ok
  end

  test "every encrypted setting decrypts under the new key to what it was" do
    assert {:ok, moved} = Rekey.run(@old, @new)
    assert moved >= 2

    for {key, value} <- [
          {"rekey.api_token", "s3cret-token"},
          {"auth.totp.secret", "JBSWY3DPEHPK3PXP"}
        ] do
      assert Crypto.decrypt_with(Crypto.key_for(@new), stored(key)) == {:ok, value}
      assert {:error, _} = Crypto.decrypt_with(Crypto.key_for(@old), stored(key))
    end
  end

  test "a value that was never encrypted is left alone" do
    {:ok, _} = Rekey.run(@old, @new)
    assert stored("rekey.plain") == "not secret"
  end

  test "every login is ended, and the rotation is audited" do
    :ok = Sessions.open(Elevation.new_sid())

    {:ok, moved} = Rekey.run(@old, @new)

    assert Repo.aggregate(AdminSession, :count) == 0

    assert Repo.exists?(
             from(e in AuditEntry,
               where:
                 e.decision == "write" and like(e.reason, ^"SECRET_KEY_BASE rotated: #{moved} %")
             )
           )
  end

  test "the wrong old key changes nothing" do
    before = stored("rekey.api_token")

    assert {:error, message} = Rekey.run(String.duplicate("w", 64), @new)
    assert message =~ "cannot be decrypted with the old SECRET_KEY_BASE"
    assert stored("rekey.api_token") == before
  end

  # After a rotation the old key decrypts nothing, so running it again is
  # refused rather than double-encrypting.
  test "a second run with the same keys is refused" do
    {:ok, _} = Rekey.run(@old, @new)
    after_first = stored("rekey.api_token")

    assert {:error, _} = Rekey.run(@old, @new)
    assert stored("rekey.api_token") == after_first
  end

  describe "credentials stored outside the settings" do
    defp raw(sql, id) do
      %{rows: [[value]]} = Repo.query!(sql, [id])
      value
    end

    defp credentials do
      {:ok, provider} =
        AlexClaw.LLM.create_provider(%{
          name: "rekey-#{System.unique_integer([:positive])}",
          type: "openai_compatible",
          tier: "light",
          model: "m",
          api_key: "sk-rekey",
          headers: %{"x-api-key" => "hdr-rekey"}
        })

      {:ok, workflow} = AlexClaw.Workflows.create_workflow(%{name: "rekey-wf"})

      {:ok, step} =
        AlexClaw.Workflows.add_step(workflow, %{
          name: "tg",
          skill: "telegram_notify",
          config: %{"bot_token" => "123:rekey", "chat_id" => "1"}
        })

      {provider.id, step.id}
    end

    defp opens_under(key_base, ciphertext),
      do: Crypto.decrypt_with(Crypto.key_for(key_base), ciphertext)

    test "move to the new key with the settings, in the same count" do
      {provider, step} = credentials()

      assert {:ok, moved} = Rekey.run(@old, @new)
      assert moved >= 5, "2 settings, the API key, one header value and the bot token"

      api_key = raw("SELECT api_key FROM llm_providers WHERE id = $1", provider)
      header = raw("SELECT headers FROM llm_providers WHERE id = $1", provider)["x-api-key"]
      bot = raw("SELECT config FROM workflow_steps WHERE id = $1", step)["bot_token"]

      assert opens_under(@new, api_key) == {:ok, "sk-rekey"}
      assert opens_under(@new, header) == {:ok, "hdr-rekey"}
      assert opens_under(@new, bot) == {:ok, "123:rekey"}
      assert {:error, _} = opens_under(@old, api_key)
      assert raw("SELECT config FROM workflow_steps WHERE id = $1", step)["chat_id"] == "1"
    end

    test "one the old key cannot decrypt refuses the whole rotation" do
      {provider, _step} = credentials()
      {:ok, foreign} = Crypto.encrypt_with(Crypto.key_for(String.duplicate("f", 64)), "x")
      Repo.query!("UPDATE llm_providers SET api_key = $2 WHERE id = $1", [provider, foreign])
      setting_before = stored("rekey.api_token")

      assert {:error, message} = Rekey.run(@old, @new)
      assert message =~ "llm_providers #{provider}: api_key cannot be decrypted"
      assert stored("rekey.api_token") == setting_before
    end
  end

  test "the same key twice is refused" do
    assert {:error, message} = Rekey.run(@old, @old)
    assert message =~ "the same"
  end
end
