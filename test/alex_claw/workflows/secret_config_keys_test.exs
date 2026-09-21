defmodule AlexClaw.Workflows.SecretConfigKeysTest do
  @moduledoc """
  A step config key named like a credential is declared secret, so it is
  stored encrypted. A core skill that names one without declaring it fails
  the build; a dynamic skill that does is refused at load.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Workflows.SkillRegistry

  setup do
    skills_dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(skills_dir)
    on_exit(fn -> File.rm_rf!(skills_dir) end)
    %{skills_dir: skills_dir}
  end

  test "every core skill declares the credential-named keys of its config" do
    undeclared =
      for module <- SkillRegistry.core_modules(),
          keys = SkillRegistry.undeclared_secrets(module),
          keys != [],
          do: {module, keys}

    assert undeclared == []
  end

  test "a credential name is matched by whole segment, not by substring" do
    for name <- ~w(api_key bot_token auth_header apikey password client_secret
                   aws_credential authorization headers extra_headers API_KEY) do
      assert SkillRegistry.credential_name?(name), "#{name} should be a credential name"
    end

    for name <- ~w(keyword_count monkey tokens_used author secretary url max_items) do
      refute SkillRegistry.credential_name?(name), "#{name} is not a credential name"
    end
  end

  test "the skills that take credentials declare them" do
    assert "bot_token" in SkillRegistry.secret_config_keys()
    assert "headers" in SkillRegistry.secret_config_keys()
  end

  defp skill(dir, name, body) do
    File.write!(Path.join(dir, name), """
    defmodule AlexClaw.Skills.Dynamic.#{Macro.camelize(Path.rootname(name))} do
      @behaviour AlexClaw.Skill
      @impl true
      def run(_args), do: {:ok, "ok", :on_success}
      @impl true
      def description, do: "secret declarations probe"
    #{body}
    end
    """)

    name
  end

  test "a dynamic skill naming an undeclared credential key is refused", %{skills_dir: dir} do
    name =
      skill(dir, "undeclared_probe.ex", """
        @impl true
        def config_scaffold, do: %{"api_key" => "", "url" => ""}
        @impl true
        def config_presets, do: %{"prod" => %{"client_secret" => ""}}
      """)

    assert {:error, {:undeclared_secrets, ["api_key", "client_secret"]}} =
             SkillRegistry.load_skill(name)

    refute Code.ensure_loaded?(AlexClaw.Skills.Dynamic.UndeclaredProbe)

    assert SkillRegistry.describe_error({:undeclared_secrets, ["api_key"]}) =~
             "secret_config_keys/0"
  end

  test "a dynamic skill that declares them loads, and its keys are encrypted", %{skills_dir: dir} do
    name =
      skill(dir, "declared_probe.ex", """
        @impl true
        def config_scaffold, do: %{"api_key" => "", "url" => ""}
        @impl true
        def secret_config_keys, do: ["api_key"]
      """)

    assert {:ok, _} = SkillRegistry.load_skill(name)
    assert "api_key" in SkillRegistry.secret_config_keys()
  end

  test "a dynamic skill with no config, or no credential-named key, needs no declaration",
       %{skills_dir: dir} do
    assert {:ok, _} = SkillRegistry.load_skill(skill(dir, "bare_probe.ex", ""))

    name =
      skill(dir, "plain_probe.ex", """
        @impl true
        def config_scaffold, do: %{"url" => "", "keyword_count" => 3}
      """)

    assert {:ok, _} = SkillRegistry.load_skill(name)
  end
end
