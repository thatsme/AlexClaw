defmodule AlexClaw.Workflows.DescribeErrorTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Workflows.SkillRegistry

  describe "describe_error/1" do
    test "each known load failure reads as a sentence" do
      cases = [
        {{:invalid_namespace, "Foo.Bar"}, "AlexClaw.Skills.Dynamic"},
        {:missing_run_callback, "run/1"},
        {{:unknown_permissions, [:wat]}, "Unknown permissions"},
        {:name_conflicts_with_core, "core skill"},
        {{:compilation_error, "syntax error"}, "Compilation error"},
        {:path_traversal, "skills directory"},
        {:file_not_found, "not found"},
        {:invalid_filename, ".ex"},
        {:not_found, "not found"},
        {:cannot_unload_core, "Core skills"},
        {{:same_version, nil, "Add a version."}, "No version defined"},
        {{:same_version, "1.0.0", "Bump it."}, "1.0.0"},
        {{:forbidden_construct, "use"}, "Not allowed"},
        {{:multiple_modules, ["A", "B"]}, "exactly one module"},
        {{:not_contained, ["File.write!/2 (not in allowlist)"]}, "contained set"},
        {{:runtime_crash, "boom"}, "Crashed"}
      ]

      for {reason, expected} <- cases do
        described = SkillRegistry.describe_error(reason)

        assert described =~ expected,
               "#{inspect(reason)} described as #{inspect(described)}"

        refute described =~ ~r/^\{|^\[/,
               "#{inspect(reason)} should not be described as a raw term"
      end
    end

    test "containment violations are all listed" do
      described =
        SkillRegistry.describe_error(
          {:not_contained,
           ["File.write!/2 (not in allowlist)", "System.cmd/2 (not in allowlist)"]}
        )

      assert described =~ "File.write!/2"
      assert described =~ "System.cmd/2"
    end

    test "a runtime validation failure nests the underlying reason" do
      described =
        SkillRegistry.describe_error({:runtime_validation, {:runtime_timeout, "took too long"}})

      assert described =~ "failed when run"
      assert described =~ "took too long"
    end

    test "an unrecognised reason falls back to inspect rather than crashing" do
      assert SkillRegistry.describe_error({:something, :new}) == "{:something, :new}"
    end

    test "a long compilation error is truncated" do
      described = SkillRegistry.describe_error({:compilation_error, String.duplicate("x", 500)})

      assert String.length(described) < 350
    end
  end
end
