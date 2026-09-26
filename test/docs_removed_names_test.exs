defmodule AlexClaw.DocsRemovedNamesTest do
  @moduledoc """
  The public docs name nothing 0.4.0 removed. An environment variable no
  longer read, a setting or chat command that no longer exists, a removed
  SkillAPI function or permission, or the retired encryption: a reader who
  follows such a name fails, or is misled about what protects the data.
  Old names belong only in the 0.4.0 release notes' Upgrading section, which
  tells an operator what to remove.

  Each name here was checked absent from lib/, config/, the compose files and
  .env.example when it was listed. `docs/reference/changelog.md` records past
  releases and is exempt.

  `@pending_review`: documents whose 0.4.0 text is proposed for review, not
  applied yet. They are checked by the same rule once applied: remove them
  from the list then.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  @removed [
    {"TELEGRAM_BOT_TOKEN", ~r/\bTELEGRAM_BOT_TOKEN\b/},
    {"GEMINI_API_KEY", ~r/\bGEMINI_API_KEY\b/},
    {"ANTHROPIC_API_KEY", ~r/\bANTHROPIC_API_KEY\b/},
    {"GOOGLE_OAUTH_CLIENT_SECRET", ~r/\bGOOGLE_OAUTH_CLIENT_SECRET\b/},
    {"GOOGLE_OAUTH_REFRESH_TOKEN", ~r/\bGOOGLE_OAUTH_REFRESH_TOKEN\b/},
    {"WEB_AUTOMATOR_TOKEN (the variable; _FILE is current)",
     ~r/\bWEB_AUTOMATOR_TOKEN\b(?!_FILE)/},
    {"OLD_SECRET_KEY_BASE", ~r/\bOLD_SECRET_KEY_BASE\b/},
    {"mcp.tool_timeout_ms", ~r/\bmcp\.tool_timeout_ms\b/},
    {"the /events chat command", ~r{(?<![\w/.])/events\b}},
    {"the /google auth chat command", ~r{(?<![\w/])/google auth\b}},
    {"the /automations chat command", ~r{(?<![\w/])/automations\b}},
    {"SkillAPI.create_workflow", ~r/\bcreate_workflow\b.*SkillAPI|SkillAPI\.create_workflow/},
    {"SkillAPI.add_workflow_step", ~r/\badd_workflow_step\b/},
    {"SkillAPI.write_skill", ~r/\bwrite_skill\b/},
    {"SkillAPI.read_skill", ~r/\bread_skill\b/},
    {"the skill_write permission", ~r/\bskill_write\b/},
    {"the skill_manage permission", ~r/\bskill_manage\b/},
    {"the workflow_manage permission", ~r/\bworkflow_manage\b/},
    {"AES-256-GCM encryption at rest", ~r/AES-256-GCM/},
    {"NimbleTOTP", ~r/\bNimbleTOTP\b/},
    {"Config.Crypto", ~r/\bConfig\.Crypto\b/},
    {"EncryptExisting", ~r/\bEncryptExisting\b/}
  ]

  @exempt ["docs/reference/changelog.md"]

  @pending_review []

  @root_docs ~w(ALEXCLAW_ARCHITECTURE.md CLA.md CODE_OF_CONDUCT.md CODING_CONVENTIONS.md
                CONTRIBUTING.md INSTALLATION.md README.md ROADMAP.md SECURITY.md SELF_AWARENESS.md)

  defp public_docs do
    (@root_docs ++ Path.wildcard("docs/**/*.md"))
    |> Enum.filter(&File.exists?/1)
    |> Kernel.--(@exempt ++ @pending_review)
  end

  test "the docs are there to check" do
    assert length(public_docs()) > 20,
           "found #{length(public_docs())} docs: the scan would be vacuous"
  end

  test "no public doc names what 0.4.0 removed" do
    found =
      for file <- public_docs(),
          {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          {what, pattern} <- @removed,
          Regex.match?(pattern, line),
          do: "#{file}:#{n}: #{what}"

    assert found == [], "removed names in the docs:\n" <> Enum.join(found, "\n")
  end
end
