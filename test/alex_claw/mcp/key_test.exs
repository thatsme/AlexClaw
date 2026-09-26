defmodule AlexClaw.MCP.KeyTest do
  @moduledoc """
  The MCP key is recognised, never retrievable (reports/V040_SECURITY_DESIGN.md
  §6; THREAT_MODEL.md P1; 0.4.0 S3).

  AlexClaw never needs the MCP key itself, only to recognise it — like a
  password. So it is not a secret AlexClaw can read back:
  - AlexClaw generates it (a person does not type it), shows it once;
  - it stores only an HMAC of it computed by OpenBao's transit engine, with
    a key AlexClaw never holds — a stolen AlexClaw database contains nothing
    that can be turned back into the key or tried offline;
  - a request is admitted when the HMAC of the presented token equals the
    stored one (constant-time comparison);
  - generating a new key replaces the old one: the old key stops working at
    once; revoking leaves no key at all (MCP refuses everything);
  - `Config.secret/2` and `Config.get/1` never return it.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.MCP.Key

  setup do
    # Inside the cleanup: on_exit runs after the test's connection is checked
    # in, and Key.revoke/0 writes to the database.
    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Key.revoke() end) end)
    :ok
  end

  test "generate returns the key once; it is recognised" do
    assert {:ok, key} = Key.generate()
    assert is_binary(key) and byte_size(key) >= 32
    assert Key.valid?(key)
  end

  test "a wrong key, an empty one, or none at all is not recognised" do
    {:ok, key} = Key.generate()

    refute Key.valid?(key <> "x")
    refute Key.valid?("")
    refute Key.valid?(nil)
  end

  test "a new key replaces the old one at once" do
    {:ok, old} = Key.generate()
    {:ok, new} = Key.generate()

    refute Key.valid?(old)
    assert Key.valid?(new)
  end

  test "after revoke, nothing is recognised" do
    {:ok, key} = Key.generate()
    :ok = Key.revoke()
    refute Key.valid?(key)
  end

  test "the key is stored nowhere: not in any table, not in OpenBao's key-value store" do
    {:ok, key} = Key.generate()

    tables =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'"
      ).rows
      |> List.flatten()

    assert length(tables) > 10

    for table <- tables do
      %{rows: rows} = Repo.query!("SELECT row_to_json(t)::text FROM \"#{table}\" t")
      refute Enum.any?(rows, fn [json] -> json =~ key end), "the MCP key is stored in #{table}"
    end

    refute match?({:ok, _}, AlexClaw.Vault.read("alexclaw/secrets/setting_mcp_api_key"))
  end

  test "it cannot be read back through the settings API" do
    {:ok, _key} = Key.generate()

    assert {:error, :not_retrievable} = AlexClaw.Config.secret("mcp.api_key", for: "inbound:mcp")
    assert_raise ArgumentError, fn -> AlexClaw.Config.get("mcp.api_key") end
  end

  test "the stored fingerprint is not the key, and differs for different keys" do
    {:ok, a} = Key.generate()
    fingerprint_a = Key.fingerprint()
    {:ok, b} = Key.generate()

    refute fingerprint_a =~ a
    refute Key.fingerprint() == fingerprint_a
    refute Key.fingerprint() =~ b
  end

  describe "the MCP endpoint" do
    import Plug.Test
    import Plug.Conn

    defp call(token) do
      conn = conn(:post, "/mcp", "{}")
      conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
      AlexClawWeb.Plugs.McpAuth.call(conn, AlexClawWeb.Plugs.McpAuth.init([]))
    end

    test "admits the current key, refuses anything else" do
      {:ok, key} = Key.generate()

      refute call(key).halted
      assert call(key <> "x").status == 401
      assert call(nil).status == 401
    end

    test "with no key configured, refuses everything" do
      :ok = Key.revoke()
      assert call("anything").status == 401
    end
  end
end
