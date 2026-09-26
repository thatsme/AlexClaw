defmodule AlexClaw.SecurityFallbacksTest do
  @moduledoc """
  A security decision does not fall back to something weaker when what it
  needs is missing or unreadable (S8 M15; THREAT_MODEL P11).

  - An LLM provider with its own key that cannot be resolved gets no key; it
    does not borrow its type's global key.
  - A stored admin password hash that cannot be read refuses every login; it
    does not reopen login to `ADMIN_PASSWORD`. Only an installation that has
    never stored one uses the variable.
  - The admin's identity settings (the password's hash, `auth.totp.*`) cannot
    be set or deleted as settings, from any entry point.
  - Policies that cannot be read deny; they are not cached as "no policies".
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{AdminPassword, AuthContext, Elevation, PolicyEngine}
  alias AlexClaw.Config.Setting
  alias AlexClaw.{ControlPlane, LLM, Secrets}
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.LLM.Client
  alias Ecto.Adapters.SQL.Sandbox

  describe "an LLM provider whose own key cannot be resolved" do
    test "gets no key, not its type's global one" do
      {:ok, _} =
        AlexClaw.Config.set("llm.gemini_api_key", "global-gemini-key-#{System.unique_integer()}")

      {:ok, provider} =
        LLM.create_provider(%{
          name: "own-#{System.unique_integer([:positive])}",
          type: "gemini",
          tier: "light",
          model: "m",
          enabled: false,
          api_key: "own-gemini-key"
        })

      %{"api_key" => %{"secret" => name}} = provider.credentials
      :ok = Secrets.delete(name)

      assert Client.resolve_api_key(provider) == ""
    end
  end

  describe "an admin password hash that cannot be read" do
    setup do
      previous = Application.get_env(:alex_claw, :admin_password)
      Application.put_env(:alex_claw, :admin_password, "the-env-password")
      on_exit(fn -> Application.put_env(:alex_claw, :admin_password, previous) end)
    end

    test "refuses the environment's password" do
      Repo.insert!(%Setting{
        key: "auth.admin_password_hash",
        value: "not-a-hash",
        type: "string",
        category: "auth",
        sensitive: true
      })

      assert {:error, :invalid_password} = AdminPassword.authenticate("the-env-password")
    end

    test "with no hash ever stored, the environment's password is used" do
      assert :ok = AdminPassword.authenticate("the-env-password")
    end
  end

  describe "the admin's identity settings" do
    setup do
      sid = Elevation.new_sid()
      on_exit(fn -> AlexClaw.SandboxCleanup.run(fn -> Elevation.revoke(sid) end) end)

      AlexClaw.Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
      {:ok, _} = Elevation.grant(sid)
      AdminPassword.store(AdminPassword.hash("the-admin"))
      %{sid: sid}
    end

    for {what, params} <- [
          {"deleting the password hash", %{key: "auth.admin_password_hash", delete: true}},
          {"setting the password hash",
           %{key: "auth.admin_password_hash", value: "$pbkdf2-sha256$1$AA==$AA==", opts: []}},
          {"turning the second factor off", %{key: "auth.totp.enabled", value: "false", opts: []}}
        ] do
      test "cannot be changed as a setting: #{what}", %{sid: sid} do
        before = AdminPassword.stored()

        assert {:error, _refused} =
                 ControlPlane.perform(
                   :set_setting,
                   unquote(Macro.escape(params)),
                   Context.admin_ui(sid)
                 )

        assert AdminPassword.stored() == before
        assert AlexClaw.Config.get("auth.totp.enabled") in [true, "true"]
      end
    end
  end

  describe "policies that cannot be read" do
    test "deny, and are not cached as none" do
      ctx = %AuthContext{caller_type: :mcp, caller: :probe, permission: :web_read}
      test_pid = self()

      # A process the database sandbox does not know: every query fails.
      Sandbox.mode(AlexClaw.Repo, :manual)
      # The reload fails too, so what evaluate sees is not a cached answer.
      spawn(fn ->
        PolicyEngine.reload_policies()
        send(test_pid, {:decision, PolicyEngine.evaluate(ctx, [])})
      end)

      assert_receive {:decision, {:deny, _reason}}, 5_000

      # Once the database answers again, so do the policies: none, here.
      :ok = Sandbox.checkout(AlexClaw.Repo)
      assert PolicyEngine.evaluate(ctx, []) == :allow
    end
  end
end
