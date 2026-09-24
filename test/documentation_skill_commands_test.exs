defmodule AlexClaw.DocumentationSkillCommandsTest do
  use ExUnit.Case, async: true
  @moduletag :docs

  # Skill load, unload, reload and create start only from the admin UI: the
  # dispatcher answers every /skill command that it is admin-UI-only
  # (dispatcher.ex). SECURITY.md, README.md and docs/security/auth.md said
  # otherwise in four places (2026-09-24), and an implementation behind those
  # commands was still in the tree, unreachable.
  #
  # The 2FA action path (execute_2fa_action/2 in auth_commands.ex) does call
  # load_skill, unload_skill and reload_skill: it is where the admin UI's
  # approved actions are performed, whether the code was typed on the page or
  # answered on a gateway. That is not a chat command and stays; what must not
  # exist is a chat COMMAND that starts one. Commands are matched on their
  # text, so the check is on the text.

  # Written out: ~w would split on the spaces.
  @chat_commands ["/skill load", "/skill unload", "/skill reload", "/skill create"]
  @docs ["README.md", "SECURITY.md", "INSTALLATION.md" | Path.wildcard("docs/**/*.md")]

  test "no document offers a chat command that loads, unloads, reloads or creates a skill" do
    offenders =
      for path <- @docs,
          File.exists?(path),
          {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          command <- @chat_commands,
          String.contains?(line, command),
          do: "#{path}:#{number}: #{String.trim(line)}"

    assert offenders == [],
           "documents offering skill management from a chat:\n  " <> Enum.join(offenders, "\n  ")
  end

  test "the dispatcher answers every /skill management command that it is admin-UI-only" do
    source = File.read!("lib/alex_claw/dispatcher.ex")
    assert source =~ ~r/only available from the Admin UI/
  end

  # Any mention in lib/, not only a match right after a quote: the boot
  # checksum notice told the admin to "Use /skill reload NAME", a command that
  # does not work, and a quote-anchored check missed it. Nothing in the code
  # has a reason to name these commands; the dispatcher's refusal does not.
  test "no code matches or mentions a chat command that loads, unloads, reloads or creates a skill" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          source = File.read!(path),
          command <- @chat_commands,
          String.contains?(source, command),
          do: "#{path}: #{command}"

    assert offenders == [],
           "code still names a skill-management chat command:\n  " <> Enum.join(offenders, "\n  ")
  end
end
