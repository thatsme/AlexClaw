defmodule AlexClaw.Skills.ShellTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.Shell

  setup do
    # Shell skill requires shell.enabled = true in config
    insert_setting("shell.enabled", "true", type: "boolean", category: "shell")
    :ok
  end

  # Widens the configured allowlist so the execution tests can run a real binary.
  defp allow(commands) do
    insert_setting("shell.whitelist", Jason.encode!(commands), category: "shell")
  end

  describe "whitelist validation" do
    test "allowed command passes" do
      assert {:ok, _result, _branch} = Shell.run(%{input: "df -h"})
    end

    test "disallowed command is rejected" do
      assert {:error, {:not_whitelisted, "rm -rf /"}} =
               Shell.run(%{input: "rm -rf /", config: %{}})
    end

    test "word-boundary enforced — 'df' does not allow 'define'" do
      assert {:error, {:not_whitelisted, "define something"}} =
               Shell.run(%{input: "define something"})
    end

    test "word-boundary allows path separator" do
      assert Shell.prefix_matches?("bin/alex_claw eval", "bin/alex_claw")
    end

    test "exact match with no trailing chars passes" do
      assert Shell.prefix_matches?("uptime", "uptime")
    end

    test "prefix followed by non-space/non-slash fails" do
      refute Shell.prefix_matches?("uptimer", "uptime")
    end
  end

  # The step supplies a command, never the rules it is checked against.
  describe "caller cannot redefine the limits" do
    test "whitelist supplied in step args is ignored" do
      assert {:error, {:not_whitelisted, "echo pwned"}} =
               Shell.run(%{input: "echo pwned", config: %{"whitelist" => ~s(["echo"])}})
    end

    test "whitelist supplied as a list in step args is ignored" do
      assert {:error, {:not_whitelisted, "echo pwned"}} =
               Shell.run(%{input: "echo pwned", config: %{"whitelist" => ["echo"]}})
    end

    test "blocklist supplied in step args cannot re-enable metacharacters" do
      allow(["ps"])

      assert {:error, {:blocked_metachar, "|"}} =
               Shell.run(%{input: "ps aux | grep beam", config: %{"blocklist" => []}})
    end

    test "step cannot raise the timeout above the configured ceiling" do
      insert_setting("shell.timeout_seconds", "1", type: "integer", category: "shell")
      allow(["sleep"])

      assert {:ok, result, :on_timeout} =
               Shell.run(%{input: "sleep 10", config: %{"timeout_seconds" => 600}})

      assert result =~ "Timed out after 1s"
    end

    test "step cannot raise the output cap above the configured ceiling" do
      insert_setting("shell.max_output_chars", "100", type: "integer", category: "shell")
      allow(["seq"])

      assert {:ok, result, :on_success} =
               Shell.run(%{input: "seq 1 10000", config: %{"max_output_chars" => 1_000_000}})

      assert result =~ "[truncated at 100 chars]"
    end

    test "step may still narrow the limits" do
      allow(["seq"])

      assert {:ok, result, :on_success} =
               Shell.run(%{input: "seq 1 10000", config: %{"max_output_chars" => 50}})

      assert result =~ "[truncated at 50 chars]"
    end
  end

  # Prefixes that previously granted far more than container introspection.
  describe "removed whitelist prefixes" do
    test "cat is no longer a prefix — /proc/self/environ is rejected" do
      assert {:error, {:not_whitelisted, "cat /proc/self/environ"}} =
               Shell.run(%{input: "cat /proc/self/environ"})
    end

    test "release binary eval is rejected" do
      assert {:error, {:not_whitelisted, _}} =
               Shell.run(%{input: "bin/alex_claw eval \"File.read!('/etc/passwd')\""})
    end

    test "curl, git, ping and nslookup are rejected" do
      for command <- ["curl https://example.com", "git clone https://x/y.git", "ping 1.1.1.1"] do
        assert {:error, {:not_whitelisted, ^command}} = Shell.run(%{input: command})
      end
    end
  end

  describe "exact command list" do
    test "a default exact entry is accepted" do
      assert {:ok, result, _branch} = Shell.run(%{input: "cat /proc/meminfo"})
      assert result =~ "$ cat /proc/meminfo"
    end

    test "an exact entry with a trailing argument is rejected" do
      assert {:error, {:not_whitelisted, "cat /proc/meminfo x"}} =
               Shell.run(%{input: "cat /proc/meminfo x"})
    end

    test "exact entry supplied in step args is ignored" do
      assert {:error, {:not_whitelisted, "cat /etc/passwd"}} =
               Shell.run(%{
                 input: "cat /etc/passwd",
                 config: %{"exact_commands" => ~s(["cat /etc/passwd"])}
               })
    end

    test "the configured exact list replaces the default" do
      insert_setting("shell.exact_commands", ~s(["date -u"]), category: "shell")

      assert {:ok, _result, _branch} = Shell.run(%{input: "date -u"})

      assert {:error, {:not_whitelisted, "cat /proc/loadavg"}} =
               Shell.run(%{input: "cat /proc/loadavg"})
    end
  end

  describe "blocklist validation" do
    test "pipe is rejected even with valid prefix" do
      assert {:error, {:blocked_metachar, "|"}} =
               Shell.run(%{input: "ps aux | grep beam"})
    end

    test "semicolon is rejected" do
      assert {:error, {:blocked_metachar, ";"}} =
               Shell.run(%{input: "df -h; rm -rf /"})
    end

    test "double ampersand is rejected" do
      assert {:error, {:blocked_metachar, "&&"}} =
               Shell.run(%{input: "uptime && cat /etc/shadow"})
    end

    test "command substitution is rejected" do
      assert {:error, {:blocked_metachar, "$("}} =
               Shell.run(%{input: "ls $(whoami)"})
    end

    test "redirect is rejected" do
      assert {:error, {:blocked_metachar, ">"}} =
               Shell.run(%{input: "ls > /tmp/out"})
    end

    test "backtick is rejected" do
      assert {:error, {:blocked_metachar, "`"}} =
               Shell.run(%{input: "ls `whoami`"})
    end
  end

  describe "execution" do
    test "successful command returns :on_success" do
      allow(["echo"])
      {:ok, result, :on_success} = Shell.run(%{input: "echo hello"})

      assert result =~ "hello"
      assert result =~ "Exit: 0"
    end

    test "output follows expected format" do
      allow(["echo"])
      {:ok, result, :on_success} = Shell.run(%{input: "echo format_test"})

      assert result =~ "$ echo format_test"
      assert result =~ ~r/Exit: 0 \| Time: \d+ms/
    end

    test "failed command returns :on_error" do
      {:ok, result, :on_error} = Shell.run(%{input: "ls /nonexistent_path_12345"})

      assert result =~ "Exit:"
    end
  end

  describe "timeout" do
    test "slow command returns :on_timeout" do
      insert_setting("shell.timeout_seconds", "1", type: "integer", category: "shell")
      allow(["sleep"])

      {:ok, result, :on_timeout} = Shell.run(%{input: "sleep 10"})

      assert result =~ "Timed out"
    end
  end

  describe "output truncation" do
    test "long output is capped with truncated marker" do
      insert_setting("shell.max_output_chars", "100", type: "integer", category: "shell")
      allow(["seq"])

      {:ok, result, :on_success} = Shell.run(%{input: "seq 1 10000"})

      assert result =~ "[truncated at 100 chars]"
    end
  end

  describe "empty/missing command" do
    test "empty input returns error" do
      assert {:error, :no_command} = Shell.run(%{input: ""})
    end

    test "nil input returns error" do
      assert {:error, :no_command} = Shell.run(%{input: nil})
    end

    test "no input or config command returns error" do
      assert {:error, :no_command} = Shell.run(%{config: %{}})
    end
  end

  describe "workflow mode" do
    test "takes command from config" do
      allow(["echo"])

      {:ok, result, :on_success} =
        Shell.run(%{config: %{"command" => "echo workflow"}, input: "ignored"})

      assert result =~ "workflow"
      refute result =~ "ignored"
    end
  end

  describe "disabled" do
    test "returns :shell_disabled when shell.enabled is not true" do
      insert_setting("shell.enabled", "false", type: "boolean", category: "shell")

      assert {:error, :shell_disabled} = Shell.run(%{input: "df -h"})
    end
  end
end
