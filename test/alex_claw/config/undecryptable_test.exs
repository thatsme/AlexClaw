defmodule AlexClaw.Config.UndecryptableTest do
  @moduledoc """
  The procedure for a SECRET_KEY_BASE lost for good: it finds every stored
  value the running key cannot decrypt, discards nothing without the exact
  confirmation, and then clears only those values, audited by row.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.AuditEntry
  alias AlexClaw.Config.{Crypto, Undecryptable}
  alias AlexClaw.Workflows

  defp foreign(plaintext) do
    {:ok, c} =
      Crypto.encrypt_with(Crypto.key_for(String.duplicate("lost-key-base", 5)), plaintext)

    c
  end

  defp raw(sql, params) do
    %{rows: [[value]]} = Repo.query!(sql, params)
    value
  end

  defp setting(key, value) do
    Repo.query!(
      "INSERT INTO settings (key, value, type, category, sensitive, inserted_at, updated_at) " <>
        "VALUES ($1, $2, 'string', 'test', true, now(), now()) " <>
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
      [key, value]
    )
  end

  # One of each: a lost setting beside a readable one, a provider whose key is
  # lost and one of whose two headers is, and a step whose bot token is lost.
  setup do
    setting("lost.token", foreign("lost-1"))
    {:ok, _} = AlexClaw.Config.set("kept.token", "still-readable", sensitive: true)

    %{rows: [[provider]]} =
      Repo.query!(
        "INSERT INTO llm_providers (name, type, tier, model, api_key, headers, enabled, priority, inserted_at, updated_at) " <>
          "VALUES ('lost-provider', 'openai_compatible', 'light', 'm', $1, $2, false, 50, now(), now()) RETURNING id",
        [
          foreign("lost-2"),
          %{"x-lost" => foreign("lost-3"), "x-kept" => Crypto.encrypt!("kept-header")}
        ]
      )

    {:ok, wf} = Workflows.create_workflow(%{name: "lost-wf"})

    {:ok, step} =
      Workflows.add_step(wf, %{name: "tg", skill: "telegram_notify", config: %{"chat_id" => "1"}})

    Repo.query!("UPDATE workflow_steps SET config = $2 WHERE id = $1", [
      step.id,
      %{"bot_token" => foreign("lost-4"), "chat_id" => "1"}
    ])

    %{provider: provider, step: step.id}
  end

  test "lists every undecryptable value by where it is, and only those", %{provider: p, step: s} do
    described = Enum.map(Undecryptable.list(), &Undecryptable.describe/1)

    assert "settings lost.token" in described
    assert "llm_providers #{p} api_key" in described
    assert "llm_providers #{p} headers" in described
    assert "workflow_steps #{s} config.bot_token" in described
    refute Enum.any?(described, &(&1 =~ "kept.token"))
  end

  test "without the confirmation, nothing is discarded", %{provider: p} do
    before = raw("SELECT api_key FROM llm_providers WHERE id = $1", [p])

    for confirmation <- [nil, "", "yes", "DISCARD", "DISCARD 999"] do
      assert {:error, message} = Undecryptable.discard(confirmation)
      assert message =~ "Not confirmed"
      assert message =~ Undecryptable.confirmation(Undecryptable.list())
    end

    assert raw("SELECT api_key FROM llm_providers WHERE id = $1", [p]) == before
    assert length(Undecryptable.list()) == 4
  end

  test "with it, only the undecryptable values are cleared, and the audit row names them",
       %{provider: p, step: s} do
    confirmation = Undecryptable.confirmation(Undecryptable.list())

    assert {:ok, discarded} = Undecryptable.discard(confirmation)
    assert length(discarded) == 4
    assert Undecryptable.list() == []

    assert raw("SELECT value FROM settings WHERE key = 'lost.token'", []) == ""
    assert AlexClaw.Config.get("kept.token") == "still-readable"
    assert raw("SELECT api_key FROM llm_providers WHERE id = $1", [p]) == nil

    headers = raw("SELECT headers FROM llm_providers WHERE id = $1", [p])
    assert headers["x-lost"] == ""
    assert Crypto.decrypt(headers["x-kept"]) == {:ok, "kept-header"}

    config = raw("SELECT config FROM workflow_steps WHERE id = $1", [s])
    assert config == %{"bot_token" => "", "chat_id" => "1"}

    [audit] =
      Repo.all(from(e in AuditEntry, where: like(e.reason, "undecryptable values discarded%")))

    assert audit.reason =~ "settings lost.token"
    assert audit.reason =~ "workflow_steps #{s} config.bot_token"
    refute audit.reason =~ "lost-"
  end

  test "with nothing undecryptable, there is nothing to discard" do
    {:ok, _} = Undecryptable.discard(Undecryptable.confirmation(Undecryptable.list()))

    assert {:error, message} = Undecryptable.discard("DISCARD 0")
    assert message =~ "Nothing to discard"
  end
end
