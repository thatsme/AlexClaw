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

    # It used to answer nil, which reads as "not set" — and the seeder believed
    # exactly that and wrote its empty default over the secret on every boot.
    # Refusing is the stronger guarantee: a caller cannot mistake the guard for
    # an absent value if it never gets an answer at all.
    test "Config.get refuses it rather than answering nil" do
      assert_raise ArgumentError, ~r/not served through Config.get/, fn ->
        Config.get("auth.totp.secret")
      end
    end

    # Since 0.4.0 (S6) TOTP reads it only to carry it into OpenBao's TOTP
    # engine, which keeps the key from then on.
    test "TOTP's own accessor can" do
      assert :imported = TOTP.import_legacy()
    end

    test "verification still works through the accessor" do
      secret = NimbleTOTP.secret()
      Config.set("auth.totp.secret", Base.encode32(secret, padding: false), type: "string")

      assert TOTP.verify(NimbleTOTP.verification_code(secret))
      refute TOTP.verify("000000")
    end

    test "an absent secret verifies nothing" do
      Config.delete("auth.totp.secret")

      refute TOTP.verify("123456")
    end
  end

  # api_request reads the resource's credential; :resources_read is inside the
  # generated auto-load ceiling. Since 0.4.0 the credential is a reference to
  # OpenBao, and a URL carrying user:password cannot be created at all.
  describe "resource credentials are redacted for skills" do
    @describetag :vault

    setup do
      {:ok, resource} =
        AlexClaw.Resources.create_resource(%{
          name: "creds-#{System.unique_integer([:positive])}",
          type: "api",
          url: "https://api.example.com/v1",
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

    test "a URL with user:password in it cannot be created in the first place" do
      assert {:error, _} =
               AlexClaw.Resources.create_resource(%{
                 name: "userinfo-#{System.unique_integer([:positive])}",
                 type: "api",
                 url: "https://user:hunter2@api.example.com/v1"
               })
    end

    test "list_resources redacts too", %{skill: skill} do
      {:ok, resources} = SkillAPI.list_resources(skill, %{type: "api"})

      refute inspect(resources) =~ "SECRET-TOKEN"
    end

    test "non-credential metadata survives", %{skill: skill, resource: resource} do
      {:ok, read} = SkillAPI.get_resource(skill, resource.id)

      assert get_in(read.metadata, ["discovery", "base_url"]) == "https://api.example.com"
    end

    # Core code reads a reference, never the value; the value comes only from
    # resolving it for the resource's host (bound to its discovered API base).
    test "core code reading Resources directly sees a reference; the value only by resolving it",
         %{resource: r} do
      {:ok, read} = AlexClaw.Resources.get_resource(r.id)

      assert %{"secret" => name} = get_in(read.metadata, ["auth", "value"])
      refute inspect(read) =~ "SECRET-TOKEN"

      assert {:ok, "Bearer SECRET-TOKEN"} =
               AlexClaw.Secrets.resolve(name, for: "host:api.example.com")
    end
  end
end
