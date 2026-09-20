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
            # Logger permits only its level functions, checked separately below.
            Logger -> ~s|Logger.info("m")|
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
      source = skill(~S|F.write!("/tmp/x", "y")|, "alias File, as: F")
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
      assert {:error, violations} = check(skill(~S|apply(File, :write!, ["/tmp/x", "y"])|))
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
      assert {:error, violations} =
               check(skill(~S|mod = File
    mod.write!("/tmp/x", "y")|))

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

  describe "Logger is limited to its level functions" do
    test "the level functions pass" do
      for level <- ~w(debug info notice warning error) do
        assert :ok = check(skill("Logger.#{level}(\"msg\")", "require Logger")),
               "expected Logger.#{level} to be allowed"
      end
    end

    # Logger also carries configuration and backend control.
    test "configuration and backend calls are refused" do
      for fun <- ~w(configure configure_backend add_backend remove_backend put_process_level) do
        assert {:error, violations} = check(skill("Logger.#{fun}(:x)", "require Logger")),
               "expected Logger.#{fun} to be refused"

        assert Enum.any?(violations, &String.contains?(&1, "level functions"))
      end
    end
  end

  describe "atom creation" do
    test "List.to_atom is refused" do
      assert {:error, violations} = check(skill("List.to_atom(args[:input])"))
      assert Enum.any?(violations, &String.contains?(&1, "to_atom"))
    end

    test "List.to_existing_atom is still allowed" do
      assert :ok = check(skill("List.to_existing_atom(args[:input])"))
    end
  end

  # Jason.decode(body, keys: :atoms) turns every key of an attacker-supplied
  # document into a permanent atom.
  describe "JSON decoding" do
    test "keys: :atoms is refused" do
      assert {:error, violations} = check(skill("Jason.decode(args[:input], keys: :atoms)"))
      assert Enum.any?(violations, &String.contains?(&1, "keys:"))
    end

    test "keys: :atoms! is refused" do
      assert {:error, violations} = check(skill("Jason.decode!(args[:input], keys: :atoms!)"))
      assert Enum.any?(violations, &String.contains?(&1, "keys:"))
    end

    test "decode without options is allowed" do
      assert :ok = check(skill("Jason.decode(args[:input])"))
    end

    test "keys: :strings is allowed" do
      assert :ok = check(skill("Jason.decode(args[:input], keys: :strings)"))
    end

    test "encode is unaffected" do
      assert :ok = check(skill("Jason.encode!(%{a: 1})"))
    end
  end

  # sweet_xml is macro-heavy and its parse options decide entity handling, which
  # this checker cannot inspect. Hand-written skills may still import it.
  describe "SweetXml" do
    test "is not available to generated code" do
      assert {:error, violations} = check(skill("SweetXml.xpath(args[:input], ~x\"//a\"l)"))
      assert Enum.any?(violations, &String.contains?(&1, "SweetXml"))
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
