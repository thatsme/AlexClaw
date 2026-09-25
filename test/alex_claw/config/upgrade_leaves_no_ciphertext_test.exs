defmodule AlexClaw.Config.UpgradeLeavesNoCiphertextTest do
  @moduledoc """
  The boot upgrade reads what 0.3.x left encrypted, once, and leaves nothing
  encrypted behind (0.4.0 S7; reports/S7_PREMISES.md Q1, Q2).

  After it has run, no row of `settings`, `llm_providers`, `workflow_steps`
  or `resources` holds a 0.3.x ciphertext (`enc:`). Each kind of value goes
  where S7 decided:
  - an LLM provider's `api_key` and each header value: into OpenBao, bound to
    the provider's host; the row keeps references;
  - a setting the admin added and marked sensitive (not a declared secret):
    into OpenBao, parked (bound to nothing it can be sent to), listed in the
    report — never dropped;
  - AlexClaw's own sensitive rows, designed to be safe at rest (the MCP key's
    fingerprint, the admin password's hash): decrypted in place, OpenBao or
    not — the admin must be able to log in while OpenBao is down;
  - a 0.3.x TOTP secret: imported into OpenBao's TOTP engine.
  A failure leaves each row as it was, is reported, and is retried at the
  next start.

  Rows are written as 0.3.x wrote them by `AlexClawTest.Legacy`.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{AdminPassword, TOTP}
  alias AlexClaw.Config.SecretUpgrade
  alias AlexClaw.LLM.Provider
  alias AlexClaw.MCP.Key
  alias AlexClaw.{Secrets, Workflows}
  alias AlexClawTest.Legacy

  defp ciphertext_left do
    [
      "SELECT count(*) FROM settings WHERE value LIKE 'enc:%'",
      "SELECT count(*) FROM llm_providers WHERE api_key LIKE 'enc:%' OR headers::text LIKE '%\"enc:%' OR credentials::text LIKE '%\"enc:%'",
      "SELECT count(*) FROM workflow_steps WHERE config::text LIKE '%\"enc:%'",
      "SELECT count(*) FROM resources WHERE metadata::text LIKE '%\"enc:%'"
    ]
    |> Enum.map(fn sql -> Repo.query!(sql).rows end)
    |> List.flatten()
    |> Enum.sum()
  end

  defp raw_provider(id) do
    %{rows: [[api_key, headers]]} =
      Repo.query!("SELECT api_key, headers FROM llm_providers WHERE id = $1", [id])

    {api_key, headers}
  end

  defp setting_value(key) do
    %{rows: rows} = Repo.query!("SELECT value FROM settings WHERE key = $1", [key])
    rows |> List.flatten() |> List.first()
  end

  defp unreachable_vault do
    config = Application.fetch_env!(:alex_claw, AlexClaw.Vault)
    name = :"vault_down_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AlexClaw.Vault, Keyword.merge(config, address: "https://127.0.0.1:1", name: name)}
    )

    name
  end

  defp legacy_provider,
    do:
      Legacy.insert_provider(%{
        host: "https://llm.example.com",
        api_key: "sk-legacy-#{System.unique_integer([:positive])}",
        headers: %{"X-Org" => "org-legacy"}
      })

  test "every kind of 0.3.x ciphertext is gone after the upgrade" do
    legacy_provider()
    Legacy.insert_setting("custom.service_token", "tok-custom", encrypted: true)
    Legacy.insert_setting("auth.admin_password_hash", AdminPassword.hash("pw"), encrypted: true)
    Legacy.insert_setting("telegram.bot_token", "123:legacy", encrypted: true)
    {:ok, workflow} = Workflows.create_workflow(%{name: "legacy-#{System.unique_integer()}"})

    Legacy.insert_step(workflow.id, "telegram_notify", %{
      "bot_token" => "123:step",
      "chat_id" => "1"
    })

    assert ciphertext_left() > 0
    assert {:ok, _report} = SecretUpgrade.run()
    assert ciphertext_left() == 0
  end

  describe "an LLM provider" do
    test "its api_key and headers move to OpenBao, bound to its host; the row keeps references" do
      id = legacy_provider()
      {sealed_key, sealed_headers} = raw_provider(id)
      api_key = Legacy.open(sealed_key)

      assert {:ok, report} = SecretUpgrade.run()
      assert "provider #{id}" in report.records_moved

      provider = Repo.get!(Provider, id)

      assert %{
               "api_key" => %{"secret" => key_name},
               "headers" => %{"X-Org" => %{"secret" => header_name}}
             } =
               provider.credentials

      assert {:ok, ^api_key} = Secrets.resolve(key_name, for: "host:llm.example.com")
      assert {:ok, "org-legacy"} = Secrets.resolve(header_name, for: "host:llm.example.com")

      assert {nil, %{}} == raw_provider(id),
             "the legacy columns still hold #{inspect(sealed_headers)}"
    end

    test "OpenBao unreachable: the row is left as it was, and reported" do
      id = legacy_provider()
      before = raw_provider(id)

      assert {:ok, report} = SecretUpgrade.run(vault: unreachable_vault())
      assert "provider #{id}" in Enum.map(report.failed, &elem(&1, 0))
      assert raw_provider(id) == before
      assert Repo.get!(Provider, id).credentials == %{}
    end
  end

  describe "a sensitive setting the admin added" do
    test "moves into OpenBao, parked, and is listed — never dropped" do
      Legacy.insert_setting("custom.service_token", "tok-custom", encrypted: true)

      assert {:ok, report} = SecretUpgrade.run()
      assert report.custom_moved == [{"custom.service_token", "setting_custom_service_token"}]

      assert %{binding: ["inbound:carried_over"]} = Secrets.get("setting_custom_service_token")
      assert Secrets.value_matches?("setting_custom_service_token", "tok-custom")
      assert setting_value("custom.service_token") == ""
    end

    test "OpenBao unreachable: the row is left as it was, and reported" do
      Legacy.insert_setting("custom.service_token", "tok-custom", encrypted: true)
      before = setting_value("custom.service_token")

      assert {:ok, report} = SecretUpgrade.run(vault: unreachable_vault())
      assert "custom.service_token" in Enum.map(report.failed, &elem(&1, 0))
      assert setting_value("custom.service_token") == before
    end
  end

  describe "AlexClaw's own sensitive rows" do
    test "the admin password's hash is decrypted in place, even with OpenBao down" do
      hash = AdminPassword.hash("pw")
      Legacy.insert_setting("auth.admin_password_hash", hash, encrypted: true)

      assert {:ok, _report} = SecretUpgrade.run(vault: unreachable_vault())
      assert AdminPassword.stored() == hash
    end

    test "the MCP key's fingerprint is decrypted in place, and the key still works" do
      key = "mcp-legacy-#{System.unique_integer([:positive])}"
      {:ok, fingerprint} = Key.fingerprint_of(key)
      Legacy.insert_setting("mcp.api_key", fingerprint, encrypted: true)

      assert {:ok, _report} = SecretUpgrade.run()
      assert setting_value("mcp.api_key") == fingerprint
      assert Key.valid?(key)
    end

    test "a 0.3.x TOTP secret is imported, and the phone's codes still work" do
      secret = NimbleTOTP.secret()

      Legacy.insert_setting("auth.totp.secret", Base.encode32(secret, padding: false),
        encrypted: true
      )

      Legacy.insert_setting("auth.totp.enabled", "true", encrypted: false)

      assert {:ok, report} = SecretUpgrade.run()
      assert report.totp == :imported
      assert :ok = TOTP.check(NimbleTOTP.verification_code(secret))
    end
  end

  test "a second run changes nothing" do
    legacy_provider()
    Legacy.insert_setting("custom.service_token", "tok-custom", encrypted: true)
    {:ok, _first} = SecretUpgrade.run()

    assert {:ok, report} = SecretUpgrade.run()
    assert report.records_moved == []
    assert report.custom_moved == []
  end
end
