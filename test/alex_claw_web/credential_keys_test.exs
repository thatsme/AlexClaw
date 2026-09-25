defmodule AlexClawWeb.CredentialKeysTest do
  @moduledoc """
  A setting whose name says it holds a credential — `api_key`, `token`,
  `password` or `secret` in its key — is refused unless it is a declared
  secret setting (0.4.0 S7; reports/S7_PREMISES.md Q2).

  Before S7 such a setting, added by the admin, was stored encrypted under
  `SECRET_KEY_BASE`. That encryption is gone; a credential belongs in
  OpenBao, and only declared secret settings are routed there. The refusal
  is at `Config.persist/3`, the write point every surface uses. Settings of
  this kind saved before 0.4.0 are carried into OpenBao by the upgrade
  (`upgrade_leaves_no_ciphertext_test.exs`).
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.Elevation
  alias AlexClaw.Config
  alias AlexClaw.Config.Setting
  alias AlexClaw.Repo

  describe "Config.persist/3" do
    for key <- ~w(custom.service_token custom.api_key billing.password vendor.client_secret) do
      test "refuses #{key}" do
        assert {:error, :undeclared_credential} = Config.persist(unquote(key), "value", [])
        refute Repo.get_by(Setting, key: unquote(key))
      end
    end

    test "stores an ordinary setting" do
      assert {:ok, _setting} = Config.persist("custom.greeting", "hello", [])
    end
  end

  test "the Config page cannot save it", %{conn: conn} do
    sid = Elevation.new_sid()
    on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)
    {:ok, _} = Elevation.grant(sid)

    {:ok, view, _html} = conn |> authenticate(sid) |> live("/config")

    render_submit(view, "save", %{
      "key" => "custom.service_token",
      "value" => "tok",
      "type" => "string",
      "description" => "",
      "category" => "custom"
    })

    refute Repo.get_by(Setting, key: "custom.service_token")
  end
end
