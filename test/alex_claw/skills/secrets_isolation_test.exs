defmodule AlexClaw.Skills.SecretsIsolationTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.TOTP
  alias AlexClaw.Config
  alias AlexClaw.Skills.SkillAPI
  alias AlexClaw.Workflows.SkillRegistry

  setup do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)

    File.write!(Path.join(skills_dir, "reader.ex"), """
    defmodule AlexClaw.Skills.Dynamic.Reader do
      @behaviour AlexClaw.Skill
      @impl true
      def permissions, do: [:config_read, :resources_read]
      @impl true
      def description, do: "reads config"
      @impl true
      def run(_args), do: {:ok, "ok", :on_success}
    end
    """)

    {:ok, _} = SkillRegistry.load_skill("reader.ex")

    on_exit(fn ->
      SkillRegistry.unload_skill("reader")
      File.rm_rf!(skills_dir)
    end)

    %{skill: AlexClaw.Skills.Dynamic.Reader}
  end

  describe "sensitive settings are refused" do
    test "credentials are not served to a skill", %{skill: skill} do
      for key <- ~w(telegram.bot_token discord.bot_token llm.gemini_api_key
                    llm.anthropic_api_key github.token github.webhook_secret
                    google.oauth.client_secret google.oauth.refresh_token) do
        Config.set(key, "SECRET-#{key}", type: "string", category: "test", sensitive: true)

        assert {:error, :sensitive} = SkillAPI.config_get(skill, key),
               "#{key} was served to a dynamic skill"
      end
    end

    test "the TOTP secret is refused", %{skill: skill} do
      Config.set("auth.totp.secret", "JBSWY3DPEHPK3PXP", type: "string", category: "auth")

      assert {:error, :sensitive} = SkillAPI.config_get(skill, "auth.totp.secret")
    end

    test "an unknown key is refused rather than assumed safe", %{skill: skill} do
      assert {:error, :sensitive} = SkillAPI.config_get(skill, "never.seeded.key")
    end

    test "non-sensitive settings still read", %{skill: skill} do
      Config.set("skills.rss.max_items", "7", type: "integer", category: "skills")

      assert {:ok, 7} = SkillAPI.config_get(skill, "skills.rss.max_items")
    end
  end

  # The second factor is not configuration; it never enters the shared cache.
  describe "TOTP secret isolation" do
    setup do
      Config.set("auth.totp.secret", "JBSWY3DPEHPK3PXP", type: "string", category: "auth")
      :ok
    end

    test "Config.get cannot serve it" do
      refute Config.get("auth.totp.secret")
    end

    test "TOTP's own accessor can" do
      assert TOTP.secret() == "JBSWY3DPEHPK3PXP"
    end

    test "verification still works through the accessor" do
      secret = NimbleTOTP.secret()
      Config.set("auth.totp.secret", Base.encode32(secret, padding: false), type: "string")

      assert TOTP.verify(NimbleTOTP.verification_code(secret))
      refute TOTP.verify("000000")
    end

    test "an absent secret verifies nothing" do
      Config.delete("auth.totp.secret")

      refute TOTP.secret()
      refute TOTP.verify("123456")
    end
  end

  # api_request reads metadata["auth"]["value"] as a literal credential, and
  # :resources_read is inside the generated auto-load ceiling.
  describe "resource credentials are redacted for skills" do
    setup do
      {:ok, resource} =
        AlexClaw.Resources.create_resource(%{
          name: "creds-#{System.unique_integer([:positive])}",
          type: "api",
          url: "https://user:hunter2@api.example.com/v1",
          metadata: %{
            "auth" => %{"header" => "authorization", "value" => "Bearer SECRET-TOKEN"},
            "discovery" => %{"base_url" => "https://api.example.com"}
          }
        })

      %{resource: resource}
    end

    test "get_resource strips the auth block", %{skill: skill, resource: resource} do
      {:ok, read} = SkillAPI.get_resource(skill, resource.id)

      refute Map.has_key?(read.metadata, "auth")
      refute inspect(read) =~ "SECRET-TOKEN"
    end

    test "get_resource strips credentials embedded in the URL", %{skill: skill, resource: r} do
      {:ok, read} = SkillAPI.get_resource(skill, r.id)

      refute read.url =~ "hunter2"
      assert read.url =~ "api.example.com"
    end

    test "list_resources redacts too", %{skill: skill} do
      {:ok, resources} = SkillAPI.list_resources(skill, %{type: "api"})

      refute inspect(resources) =~ "SECRET-TOKEN"
      refute inspect(resources) =~ "hunter2"
    end

    test "non-credential metadata survives", %{skill: skill, resource: resource} do
      {:ok, read} = SkillAPI.get_resource(skill, resource.id)

      assert get_in(read.metadata, ["discovery", "base_url"]) == "https://api.example.com"
    end

    # api_request is core code and must keep working.
    test "core code reading Resources directly still sees the credential", %{resource: r} do
      {:ok, read} = AlexClaw.Resources.get_resource(r.id)

      assert get_in(read.metadata, ["auth", "value"]) == "Bearer SECRET-TOKEN"
      assert read.url =~ "hunter2"
    end
  end
end
