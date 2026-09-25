defmodule AlexClaw.EncryptedTest do
  @moduledoc """
  Credentials stored outside the settings are encrypted at rest: what the
  database holds is `enc:` ciphertext, what the schema hands back is the
  value, and a stored value that does not decrypt is an error, not a blank.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config.Crypto
  alias AlexClaw.{LLM, Workflows}
  alias AlexClaw.LLM.Provider
  alias AlexClaw.Workflows.WorkflowStep

  setup do
    # 0.3.54: a telegram_notify step is saved only when Telegram is configured.
    insert_setting("telegram.enabled", "true", type: "boolean", category: "telegram")
    insert_setting("telegram.bot_token", "test-token", type: "string", category: "telegram")
    :ok
  end

  defp provider(attrs) do
    base = %{
      name: "enc-#{System.unique_integer([:positive])}",
      type: "openai_compatible",
      tier: "light",
      model: "m"
    }

    {:ok, provider} = LLM.create_provider(Map.merge(base, attrs))
    provider
  end

  defp raw(sql, id) do
    %{rows: [[value]]} = Repo.query!(sql, [id])
    value
  end

  defp step(skill, config) do
    {:ok, workflow} =
      Workflows.create_workflow(%{name: "enc-#{System.unique_integer([:positive])}"})

    {:ok, step} = Workflows.add_step(workflow, %{name: "s", skill: skill, config: config})
    step
  end

  defp foreign(plaintext) do
    {:ok, ciphertext} =
      Crypto.encrypt_with(Crypto.key_for(String.duplicate("another-key-base", 4)), plaintext)

    ciphertext
  end

  describe "an LLM provider" do
    test "stores its API key and header values encrypted, and reads them back" do
      p = provider(%{api_key: "sk-secret", headers: %{"x-api-key" => "hdr-secret"}})

      stored_key = raw("SELECT api_key FROM llm_providers WHERE id = $1", p.id)
      stored_headers = raw("SELECT headers FROM llm_providers WHERE id = $1", p.id)

      assert Crypto.encrypted?(stored_key)
      assert Map.keys(stored_headers) == ["x-api-key"], "header names stay readable"
      assert Crypto.encrypted?(stored_headers["x-api-key"])

      read = Repo.get!(Provider, p.id)
      assert read.api_key == "sk-secret"
      assert read.headers == %{"x-api-key" => "hdr-secret"}
    end

    test "with no key and no headers stores nothing encrypted" do
      p = provider(%{api_key: nil})
      assert raw("SELECT api_key FROM llm_providers WHERE id = $1", p.id) == nil
      assert raw("SELECT headers FROM llm_providers WHERE id = $1", p.id) == %{}
      assert Repo.get!(Provider, p.id).headers == %{}
    end

    test "whose stored key does not decrypt cannot be read" do
      p = provider(%{api_key: "sk-secret"})
      Repo.query!("UPDATE llm_providers SET api_key = $2 WHERE id = $1", [p.id, foreign("x")])

      assert_raise RuntimeError, ~r/does not decrypt/, fn -> Repo.get!(Provider, p.id) end
    end
  end

  describe "a workflow step's config" do
    # Since 0.4.0 (S4a) a step's credential is not encrypted in the row: it is
    # a reference to OpenBao, and the row holds no ciphertext of it at all.
    # Legacy rows sealed under SECRET_KEY_BASE are read until the upgrade
    # moves them (the "does not decrypt" test below still covers those).
    @describetag :vault

    test "stores a declared secret key as a reference, and nothing else changes" do
      s = step("telegram_notify", %{"bot_token" => "123:bot-secret", "chat_id" => "42"})
      stored = raw("SELECT config FROM workflow_steps WHERE id = $1", s.id)

      assert %{"secret" => _name} = stored["bot_token"]
      refute inspect(stored) =~ "bot-secret"
      assert stored["chat_id"] == "42"

      # The schema hands back the reference, never the value.
      assert %{"secret" => _} = Repo.get!(WorkflowStep, s.id).config["bot_token"]
    end

    test "a credential header becomes a reference; an ordinary header stays as it is" do
      headers = %{"authorization" => "Bearer api-secret", "accept" => "application/json"}
      s = step("api_request", %{"url" => "https://example.com", "headers" => headers})
      stored = raw("SELECT config FROM workflow_steps WHERE id = $1", s.id)

      assert %{"secret" => _} = stored["headers"]["authorization"]
      assert stored["headers"]["accept"] == "application/json"
      refute inspect(stored) =~ "api-secret"
      assert stored["url"] == "https://example.com"
    end

    test "leaves an empty secret, and a config without one, as they are" do
      s = step("telegram_notify", %{"bot_token" => "", "chat_id" => "1"})
      assert raw("SELECT config FROM workflow_steps WHERE id = $1", s.id)["bot_token"] == ""

      plain = step("web_fetch", %{"url" => "https://example.com"})

      assert raw("SELECT config FROM workflow_steps WHERE id = $1", plain.id) == %{
               "url" => "https://example.com"
             }
    end

    # Only declared keys are decrypted: text a user typed elsewhere that
    # happens to begin "enc:" is not mistaken for ciphertext.
    test "does not decrypt an undeclared key that merely looks encrypted" do
      s = step("web_fetch", %{"url" => "enc:not-ciphertext"})
      assert Repo.get!(WorkflowStep, s.id).config["url"] == "enc:not-ciphertext"
    end

    test "whose stored secret does not decrypt cannot be read" do
      s = step("telegram_notify", %{"bot_token" => "t"})

      Repo.query!("UPDATE workflow_steps SET config = $2 WHERE id = $1", [
        s.id,
        %{"bot_token" => foreign("t")}
      ])

      assert_raise RuntimeError, ~r/does not decrypt/, fn -> Repo.get!(WorkflowStep, s.id) end
    end
  end

  # Ciphertext takes a fresh IV every time, so a query filtering on an
  # encrypted column matches nothing and fails silently. None may exist.
  describe "nothing in lib/ queries an encrypted credential" do
    @ecto_filter ~r/\b(where|order_by|group_by|distinct)\b[:(\s][^\n]*\.(api_key|headers|config)\b/
    # After WHERE, AND, OR, ON or BY: a condition, not a SET assignment.
    @sql_filter ~r/"[^"\n]*\b(WHERE|AND|OR|ON|BY)\b[^"\n]*\b(api_key|headers|config)\b\s*(->>|->|#>>|#>|@>|\?|=|ILIKE|LIKE)[^"\n]*"/i

    test "by Ecto query or by SQL" do
      offenders =
        for path <- Path.wildcard("lib/**/*.{ex,exs}"),
            {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            Regex.match?(@ecto_filter, line) or Regex.match?(@sql_filter, line),
            do: "#{path}:#{n}: #{String.trim(line)}"

      assert offenders == []
    end

    test "the scan finds the queries it is for" do
      assert Regex.match?(@ecto_filter, "where: p.api_key == ^key")
      assert Regex.match?(@ecto_filter, "|> where([s], s.config == ^c)")

      assert Regex.match?(
               @sql_filter,
               ~s|"SELECT id FROM workflow_steps WHERE config ->> 'bot_token' = $1"|
             )

      refute Regex.match?(@sql_filter, ~s|"SELECT id, api_key, headers FROM llm_providers"|)
      refute Regex.match?(@sql_filter, ~s|"UPDATE llm_providers SET api_key = $2 WHERE id = $1"|)
      assert Regex.match?(@sql_filter, ~s|"UPDATE t SET x = 1 WHERE api_key = $1"|)
    end
  end
end
