defmodule AlexClaw.Skills.PathContainmentTest do
  @moduledoc """
  A contained skill may take paths apart and put them together, and nothing
  more (S8 M14; THREAT_MODEL P9): `Path.wildcard/2` lists the filesystem, and
  `Path.expand`, `Path.absname` and `Path.relative_to_cwd` read the working
  directory or the home directory. `Path` is allowed function by function.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Skills.CallPolicy

  for call <- [
        quote(do: Path.wildcard("/app/**")),
        quote(do: Path.wildcard("/etc/*", match_dot: true)),
        quote(do: Path.expand("~")),
        quote(do: Path.expand("x", "/")),
        quote(do: Path.absname("x")),
        quote(do: Path.relative_to_cwd("/app"))
      ] do
    test "refuses #{Macro.to_string(call)}" do
      assert {:error, [_violation]} = CallPolicy.contained?(unquote(Macro.escape(call)))
    end
  end

  for call <- [
        quote(do: Path.join("a", "b")),
        quote(do: Path.join(["a", "b"])),
        quote(do: Path.basename("a/b.txt")),
        quote(do: Path.dirname("a/b.txt")),
        quote(do: Path.extname("a/b.txt")),
        quote(do: Path.rootname("a/b.txt")),
        quote(do: Path.split("a/b")),
        quote(do: Path.relative_to("/a/b", "/a")),
        quote(do: Path.type("a"))
      ] do
    test "allows #{Macro.to_string(call)}" do
      assert :ok = CallPolicy.contained?(unquote(Macro.escape(call)))
    end
  end
end
