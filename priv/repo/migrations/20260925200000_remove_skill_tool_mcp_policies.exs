defmodule AlexClaw.Repo.Migrations.RemoveSkillToolMcpPolicies do
  use Ecto.Migration

  # MCP no longer exposes skills as tools (0.4.0): a client runs workflows.
  # An mcp_restriction policy for a `skill:` tool guards a tool that does not
  # exist, so it goes. `down` restores the four denies SeedMcpDefaultDenies
  # seeded; any other skill: policy an operator had added is not restored.
  @seeded ~w(skill:shell skill:coder skill:db_backup skill:web_automation)

  def up do
    execute("""
    DELETE FROM auth_policies
    WHERE rule_type = 'mcp_restriction'
      AND config->>'tool_pattern' LIKE 'skill:%'
    """)
  end

  def down do
    for tool <- @seeded do
      config =
        Jason.encode!(%{"tool_pattern" => tool, "action" => "deny", "match" => "exact"})

      execute("""
      INSERT INTO auth_policies
        (name, description, rule_type, config, enabled, priority, inserted_at, updated_at)
      SELECT
        'MCP deny #{tool}',
        'Denies #{tool} over MCP. Disable or delete this policy to allow it.',
        'mcp_restriction',
        '#{config}'::jsonb,
        true,
        100,
        NOW() AT TIME ZONE 'utc',
        NOW() AT TIME ZONE 'utc'
      WHERE NOT EXISTS (
        SELECT 1 FROM auth_policies WHERE name = 'MCP deny #{tool}'
      )
      """)
    end
  end
end
