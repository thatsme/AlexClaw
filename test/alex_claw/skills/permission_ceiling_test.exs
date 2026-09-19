defmodule AlexClaw.Skills.PermissionCeilingTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Skills.CallPolicy

  describe "permitted?/1" do
    test "the allowed set passes individually" do
      for permission <- CallPolicy.auto_load_permissions() do
        assert :ok = CallPolicy.permitted?([permission])
      end
    end

    test "no permissions at all passes" do
      assert :ok = CallPolicy.permitted?([])
    end

    # :skill_invoke reaches core skills through SkillAPI.run_skill/3, including
    # shell and coder, neither of which checks 2FA inside run/1.
    test "skill_invoke is refused" do
      assert {:error, reasons} = CallPolicy.permitted?([:llm, :skill_invoke])
      assert Enum.any?(reasons, &String.contains?(&1, ":skill_invoke"))
    end

    # config_get returns decrypted values: ETS holds plaintext for sensitive keys.
    test "config_read is refused" do
      assert {:error, reasons} = CallPolicy.permitted?([:config_read])
      assert Enum.any?(reasons, &String.contains?(&1, ":config_read"))
    end

    test "the write permissions are refused" do
      for permission <- [:memory_write, :knowledge_write, :skill_write, :skill_manage] do
        assert {:error, reasons} = CallPolicy.permitted?([permission])
        assert Enum.any?(reasons, &String.contains?(&1, ":#{permission}"))
      end
    end

    test "every disqualifying permission is named, not just the first" do
      assert {:error, reasons} = CallPolicy.permitted?([:skill_invoke, :config_read])
      assert length(reasons) == 2
    end
  end

  describe "read-private plus network" do
    test "web_read with each private read is refused" do
      for read <- [:memory_read, :knowledge_read, :resources_read] do
        assert {:error, reasons} = CallPolicy.permitted?([:web_read, read])

        assert Enum.any?(reasons, &String.contains?(&1, "web_read together with")),
               "expected an exfiltration reason for #{read}, got #{inspect(reasons)}"
      end
    end

    test "the reason names every private read held" do
      assert {:error, [reason]} =
               CallPolicy.permitted?([:web_read, :memory_read, :knowledge_read])

      assert reason =~ ":memory_read"
      assert reason =~ ":knowledge_read"
    end

    test "web_read alone is allowed" do
      assert :ok = CallPolicy.permitted?([:llm, :web_read])
    end

    test "private reads without web_read are allowed" do
      assert :ok = CallPolicy.permitted?([:memory_read, :knowledge_read, :resources_read])
    end

    test "gateway_send with a private read is allowed" do
      # Output goes to the configured chat, not an arbitrary destination.
      assert :ok = CallPolicy.permitted?([:memory_read, :gateway_send])
    end
  end
end
