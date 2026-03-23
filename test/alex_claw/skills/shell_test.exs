defmodule AlexClaw.Skills.ShellTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Skills.Shell

  setup do
    # Shell skill requires shell.enabled = true in config
    insert_setting("shell.enabled", "true", type: "boolean", category: "shell")
    :ok
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
      {:ok, result, :on_success} = Shell.run(%{
        input: "echo hello",
        config: %{"whitelist" => ~s(["echo"])}
      })
      assert result =~ "hello"
      assert result =~ "Exit: 0"
    end

    test "output follows expected format" do
      {:ok, result, :on_success} = Shell.run(%{
        input: "echo format_test",
        config: %{"whitelist" => ~s(["echo"])}
      })
      assert result =~ "$ echo format_test"
      assert result =~ ~r/Exit: 0 \| Time: \d+ms/
    end

    test "failed command returns :on_error" do
      {:ok, result, :on_error} = Shell.run(%{
        input: "ls /nonexistent_path_12345",
        config: %{"whitelist" => ~s(["ls"])}
      })
      assert result =~ "Exit:"
    end
  end

  describe "timeout" do
    test "slow command returns :on_timeout" do
      {:ok, result, :on_timeout} = Shell.run(%{
        input: "sleep 10",
        config: %{
          "whitelist" => ~s(["sleep"]),
          "timeout_seconds" => 1
        }
      })
      assert result =~ "Timed out"
    end
  end

  describe "output truncation" do
    test "long output is capped with truncated marker" do
      # seq generates plenty of output
      {:ok, result, :on_success} = Shell.run(%{
        input: "seq 1 10000",
        config: %{
          "whitelist" => ~s(["seq"]),
          "max_output_chars" => 100
        }
      })
      assert result =~ "[truncated at 100 chars]"
    end
  end

  describe "config override" do
    test "custom whitelist is respected" do
      {:ok, result, :on_success} = Shell.run(%{
        input: "echo custom",
        config: %{"whitelist" => ~s(["echo"])}
      })
      assert result =~ "custom"
    end

    test "custom timeout is respected" do
      {:ok, _result, :on_timeout} = Shell.run(%{
        input: "sleep 5",
        config: %{
          "whitelist" => ~s(["sleep"]),
          "timeout_seconds" => 1
        }
      })
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
      {:ok, result, :on_success} = Shell.run(%{
        config: %{
          "command" => "echo workflow",
          "whitelist" => ~s(["echo"])
        },
        input: "ignored"
      })
      assert result =~ "workflow"
      refute result =~ "ignored"
    end
  end
end
