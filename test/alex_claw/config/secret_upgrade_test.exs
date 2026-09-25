defmodule AlexClaw.Config.SecretUpgradeTest do
  @moduledoc """
  Upgrading to 0.4.0 carries every existing credential over, unchanged
  (reports/V040_SECURITY_DESIGN.md S7 — Alex's hard requirement: no
  credential may be lost or need re-creating).

  At the first start of 0.4.0, before the gateways, `Config.SecretUpgrade`
  finds each secret setting still holding a value in the settings table (as
  0.3.x left it: encrypted, or plaintext), and:
  1. reads it (decrypting with the current key);
  2. writes it to OpenBao;
  3. reads it back and compares;
  4. only then empties the database copy.
  Any failure leaves the database copy exactly as it was, is reported by the
  key's name, and is retried at the next start. The MCP key is the one
  exception: it becomes its HMAC fingerprint (computed twice and compared
  before the row is touched), so a configured client keeps working.

  Rows are written the way 0.3.x wrote them by
  `AlexClawTest.Legacy.insert_setting/3` (test support, below the line of
  the current Config API, which would route them).
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Config
  alias AlexClaw.Config.SecretUpgrade
  alias AlexClawTest.Legacy

  @token "123456-legacy-token-#{System.unique_integer([:positive])}"

  defp db_value(key) do
    %{rows: rows} = Repo.query!("SELECT value FROM settings WHERE key = $1", [key])
    rows |> List.flatten() |> List.first()
  end

  test "an encrypted 0.3.x token is moved, resolves to the same value, and leaves the table" do
    Legacy.insert_setting("telegram.bot_token", @token, encrypted: true)

    assert {:ok, report} = SecretUpgrade.run()
    assert "telegram.bot_token" in report.moved

    assert {:ok, @token} =
             Config.secret("telegram.bot_token", for: Config.secret_binding("telegram.bot_token"))

    assert db_value("telegram.bot_token") in [nil, ""]
  end

  test "a plaintext 0.3.x row is moved the same way" do
    Legacy.insert_setting("github.token", "ghp-legacy-plain", encrypted: false)

    assert {:ok, report} = SecretUpgrade.run()
    assert "github.token" in report.moved
    assert {:ok, "ghp-legacy-plain"} = Config.secret("github.token", for: "host:api.github.com")
  end

  test "OpenBao unreachable: nothing moves, the database copy is untouched and still decrypts" do
    Legacy.insert_setting("telegram.bot_token", @token, encrypted: true)
    before = db_value("telegram.bot_token")

    config = Application.fetch_env!(:alex_claw, AlexClaw.Vault)
    down = :"vault_down_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AlexClaw.Vault, Keyword.merge(config, address: "https://127.0.0.1:1", name: down)}
    )

    assert {:ok, report} = SecretUpgrade.run(vault: down)
    assert "telegram.bot_token" in Enum.map(report.failed, &elem(&1, 0))
    assert db_value("telegram.bot_token") == before
    assert Legacy.decrypt_setting("telegram.bot_token") == @token
  end

  test "a second run changes nothing" do
    Legacy.insert_setting("telegram.bot_token", @token, encrypted: true)

    {:ok, _} = SecretUpgrade.run()
    assert {:ok, report} = SecretUpgrade.run()

    assert report.moved == []

    assert {:ok, @token} =
             Config.secret("telegram.bot_token", for: Config.secret_binding("telegram.bot_token"))
  end

  test "an existing MCP key becomes its fingerprint: the configured client keeps working" do
    old_key = "legacy-mcp-key-" <> Base.encode16(:crypto.strong_rand_bytes(24))
    Legacy.insert_setting("mcp.api_key", old_key, encrypted: true)

    assert {:ok, _} = SecretUpgrade.run()

    assert AlexClaw.MCP.Key.valid?(old_key)
    refute AlexClaw.MCP.Key.valid?(old_key <> "x")
    refute inspect(db_value("mcp.api_key")) =~ old_key
  end

  test "every declared secret key is handled (no key forgotten by the upgrade)" do
    for key <- Config.SecretSettings.keys() do
      Legacy.insert_setting(key, "legacy-#{key}-value", encrypted: true)
    end

    assert {:ok, report} = SecretUpgrade.run()

    assert Enum.sort(report.moved ++ report.fingerprinted) ==
             Enum.sort(Config.SecretSettings.keys()),
           "keys not carried over: #{inspect(Config.SecretSettings.keys() -- (report.moved ++ report.fingerprinted))}"
  end
end
