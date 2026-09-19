defmodule AlexClaw.Repo.Migrations.SeedMcpDefaultDenies do
  use Ecto.Migration

  # MCP exposes every registered skill as a callable tool, gated only by the
  # bearer token on the transport. These four reach the host, the filesystem or
  # the network, so they are denied by default and must be enabled deliberately.
  @denied ~w(skill:shell skill:coder skill:db_backup skill:web_automation)

  # Raw SQL rather than the Policy schema: a migration must keep working when the
  # schema changes, and it lets the jsonb config be cast explicitly.
  def up do
    for tool <- @denied do
      config =
        Jason.encode!(%{"tool_pattern" => tool, "action" => "deny", "match" => "exact"})

      execute(
        """
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
        """,
        "DELETE FROM auth_policies WHERE name = 'MCP deny #{tool}'"
      )
    end
  end
end
