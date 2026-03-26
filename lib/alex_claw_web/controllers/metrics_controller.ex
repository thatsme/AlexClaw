defmodule AlexClawWeb.MetricsController do
  @moduledoc "Rich metrics endpoint for authenticated admin. Returns system, LLM, workflow, skill, and log statistics."
  use Phoenix.Controller, formats: [:json]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{
      system: system_metrics(),
      llm: llm_metrics(),
      workflows: AlexClaw.Workflows.run_stats_today(),
      skills: skill_metrics(),
      logs: AlexClaw.LogBuffer.counts(),
      knowledge: %{entries: AlexClaw.Knowledge.count()},
      memory: %{entries: AlexClaw.Memory.count()}
    })
  end

  defp system_metrics do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    %{
      uptime_seconds: div(uptime_ms, 1000),
      memory_bytes: :erlang.memory(:total),
      beam_process_count: :erlang.system_info(:process_count)
    }
  end

  defp llm_metrics do
    providers =
      Enum.map(AlexClaw.LLM.list_providers(), fn p ->
        %{
          name: p.name,
          tier: p.tier,
          enabled: p.enabled,
          usage_today: AlexClaw.LLM.usage_today(p.id)
        }
      end)

    %{
      providers: providers,
      total_calls_today: Enum.reduce(providers, 0, fn p, acc -> acc + p.usage_today end)
    }
  end

  defp skill_metrics do
    children = DynamicSupervisor.count_children(AlexClaw.SkillSupervisor)

    breakers =
      case :ets.info(:circuit_breakers) do
        :undefined ->
          %{}

        _ ->
          :circuit_breakers
          |> :ets.tab2list()
          |> Map.new(fn {name, state, count, last_error, _ts} ->
            {name, %{state: state, failure_count: count, last_error: format_error(last_error)}}
          end)
      end

    %{
      active: children.active,
      total_registered: length(AlexClaw.Workflows.SkillRegistry.list_skills()),
      circuit_breakers: breakers
    }
  end

  defp format_error(nil), do: nil
  defp format_error(error), do: String.slice(inspect(error), 0, 200)
end
