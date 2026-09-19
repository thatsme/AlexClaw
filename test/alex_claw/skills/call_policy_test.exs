defmodule AlexClaw.Skills.CallPolicyTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Skills.CallPolicy

  defp check(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    CallPolicy.contained?(ast)
  end

  defp skill(body, header \\ "") do
    """
    defmodule AlexClaw.Skills.Dynamic.Probe do
      @behaviour AlexClaw.Skill
      #{header}
      @impl true
      def run(args) do
        #{body}
      end
    end
    """
  end

  describe "allowed modules" do
    test "every allowlisted module passes" do
      for module <- CallPolicy.allowed_modules() do
        call =
          case module do
            :math -> ":math.pi()"
            other -> "#{inspect(other)}.__info__(:module)"
          end

        assert :ok = check(skill(call)), "expected #{inspect(module)} to be allowed"
      end
    end

    test "a realistic contained skill passes" do
      source =
        skill(
          """
          case AlexClaw.Skills.SkillAPI.http_get(__MODULE__, args[:input]) do
            {:ok, %{status: 200, body: body}} ->
              text = body |> Floki.parse_document!() |> Floki.text() |> String.slice(0, 500)
              {:ok, summary} = AlexClaw.Skills.SkillAPI.llm_complete(__MODULE__, text)
              Logger.info("done")
              {:ok, summary, :on_success}

            _other ->
              {:error, :fetch_failed}
          end
          """,
          "require Logger"
        )

      assert :ok = check(source)
    end

    test "a self-call via __MODULE__ is allowed" do
      assert :ok = check(skill("__MODULE__.helper(args)"))
    end
  end

  describe "modules outside the allowlist" do
    test "each escape route is rejected" do
      cases = [
        {~s|File.write!("/tmp/x", "y")|, "File"},
        {~s|System.cmd("ls", [])|, "System"},
        {~s|Code.eval_string("1")|, "Code"},
        {~s|Module.create(X, [], [])|, "Module"},
        {~s|:os.cmd(~c"ls")|, ":os"},
        {~s|Req.get("https://example.com")|, "Req"},
        {~s|AlexClaw.Repo.all(X)|, "AlexClaw.Repo"},
        {~s|Port.open({:spawn, "ls"}, [])|, "Port"},
        {~s|Process.exit(self(), :kill)|, "Process"},
        {~s|Node.list()|, "Node"}
      ]

      for {call, label} <- cases do
        assert {:error, violations} = check(skill(call)),
               "expected #{label} to be rejected"

        assert Enum.any?(violations, &String.contains?(&1, label)),
               "expected a violation naming #{label}, got #{inspect(violations)}"
      end
    end

    test "the violation names the function and arity" do
      assert {:error, violations} = check(skill(~s|File.write!("/tmp/x", "y")|))
      assert "File.write!/2 (not in allowlist)" in violations
    end
  end

  describe "aliases" do
    test "an alias of an allowed module resolves and passes" do
      assert :ok =
               check(
                 skill(
                   "Skills.SkillAPI.llm_complete(__MODULE__, \"hi\")",
                   "alias AlexClaw.Skills"
                 )
               )
    end

    test "an alias of an allowed module used directly passes" do
      source =
        skill("SkillAPI.llm_complete(__MODULE__, \"hi\")", "alias AlexClaw.Skills.SkillAPI")

      assert :ok = check(source)
    end

    test "an alias of a denied module is still rejected" do
      source = skill("Repo.all(X)", "alias AlexClaw.Repo")
      assert {:error, violations} = check(source)
      assert Enum.any?(violations, &String.contains?(&1, "AlexClaw.Repo"))
    end

    test "alias with :as is refused" do
      source = skill("F.write!(\"/tmp/x\", \"y\")", "alias File, as: F")
      assert {:error, violations} = check(source)
      assert Enum.any?(violations, &String.contains?(&1, "as:"))
    end

    test "the multi-alias brace form is refused" do
      source = skill("Enum.count([])", "alias AlexClaw.Skills.{SkillAPI, Helpers}")
      assert {:error, violations} = check(source)
      assert Enum.any?(violations, &String.contains?(&1, "multi-alias"))
    end
  end

  describe "dynamic dispatch" do
    test "apply/3 is rejected" do
      assert {:error, violations} = check(skill("apply(File, :write!, [\"/tmp/x\", \"y\"])"))
      assert Enum.any?(violations, &String.contains?(&1, "apply"))
    end

    test "apply/2 is rejected" do
      assert {:error, violations} = check(skill("apply(fun, [])"))
      assert Enum.any?(violations, &String.contains?(&1, "apply"))
    end

    test "Kernel.apply is rejected" do
      assert {:error, violations} = check(skill("Kernel.apply(File, :write!, [])"))
      assert Enum.any?(violations, &String.contains?(&1, "apply"))
    end

    test ":erlang.apply is rejected" do
      assert {:error, violations} = check(skill(":erlang.apply(File, :write!, [])"))
      assert Enum.any?(violations, &String.contains?(&1, "apply"))
    end

    test "a call on a variable module is rejected" do
      assert {:error, violations} = check(skill("mod = File\n    mod.write!(\"/tmp/x\", \"y\")"))
      assert Enum.any?(violations, &String.contains?(&1, "dynamic dispatch"))
    end
  end

  describe "process primitives" do
    test "spawn, spawn_link, spawn_monitor and send are rejected" do
      for local <- ~w(spawn spawn_link spawn_monitor) do
        assert {:error, violations} = check(skill("#{local}(fn -> :ok end)"))
        assert Enum.any?(violations, &String.contains?(&1, local))
      end

      assert {:error, violations} = check(skill("send(self(), :msg)"))
      assert Enum.any?(violations, &String.contains?(&1, "send"))
    end
  end

  describe "captures" do
    test "a capture of a denied module is rejected" do
      assert {:error, violations} = check(skill("Enum.map([], &File.read/1)"))
      assert Enum.any?(violations, &String.contains?(&1, "File.read"))
    end

    test "a capture of an allowed module passes" do
      assert :ok = check(skill("Enum.map([], &String.trim/1)"))
    end
  end

  describe "denied functions inside allowed modules" do
    test "String.to_atom is rejected" do
      assert {:error, violations} = check(skill("String.to_atom(args[:input])"))
      assert Enum.any?(violations, &String.contains?(&1, "to_atom"))
    end

    test "String.to_existing_atom is still allowed" do
      assert :ok = check(skill("String.to_existing_atom(args[:input])"))
    end
  end

  describe "reporting" do
    test "every violation is reported, not just the first" do
      source =
        skill("""
        File.write!("/tmp/a", "x")
        System.cmd("ls", [])
        Code.eval_string("1")
        """)

      assert {:error, violations} = check(source)
      assert length(violations) >= 3
      assert Enum.any?(violations, &String.contains?(&1, "File"))
      assert Enum.any?(violations, &String.contains?(&1, "System"))
      assert Enum.any?(violations, &String.contains?(&1, "Code"))
    end

    test "duplicate violations are collapsed" do
      source =
        skill("""
        File.write!("/tmp/a", "x")
        File.write!("/tmp/b", "y")
        """)

      assert {:error, violations} = check(source)
      assert violations == ["File.write!/2 (not in allowlist)"]
    end
  end
end
