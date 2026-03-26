defmodule AlexClawWeb.AdminLive.Dashboard do
  @moduledoc "LiveView dashboard showing system uptime, memory usage, LLM stats, and recent activity."

  use Phoenix.LiveView
  import AlexClawWeb.TimeHelpers


  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5_000, :refresh)
    end

    {:ok, assign_stats(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_stats(socket)}
  end

  defp assign_stats(socket) do
    skill_children = DynamicSupervisor.count_children(AlexClaw.SkillSupervisor)
    memory_bytes = :erlang.memory(:total)

    assign(socket,
      page_title: "Dashboard",
      version: to_string(Application.spec(:alex_claw, :vsn)),
      uptime: format_uptime(:erlang.statistics(:wall_clock) |> elem(0) |> div(1000)),
      memory_mb: div(memory_bytes, 1_048_576),
      skills_active: skill_children.active,
      skills_total: skill_children.workers,
      update_status: AlexClaw.UpdateChecker.status(),
      llm_usage: get_llm_usage(),
      google_status: AlexClaw.Google.TokenManager.status(),
      recent_memories: AlexClaw.Memory.recent(limit: 20),
      cluster_warnings: cluster_warnings()
    )
  end

  defp get_llm_usage do
    AlexClaw.LLM.list_providers()
    |> Enum.map(fn p -> {p.name, AlexClaw.LLM.usage_today(p.id)} end)
    |> Enum.reject(fn {_, c} -> c == 0 end)
  end

  defp format_uptime(total_seconds) do
    days = div(total_seconds, 86400)
    hours = div(rem(total_seconds, 86400), 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    secs = rem(total_seconds, 60)

    [{days, "d"}, {hours, "h"}, {minutes, "m"}]
    |> Enum.filter(fn {val, _} -> val > 0 end)
    |> Enum.map(fn {val, unit} -> "#{val}#{unit}" end)
    |> Kernel.++(["#{secs}s"])
    |> Enum.join(" ")
  end

  defp google_label(:connected), do: "Connected"
  defp google_label(:expired), do: "Token expired"
  defp google_label(:not_configured), do: "Not configured"
  defp google_label(_), do: "Error"

  defp cluster_warnings do
    if Node.list() == [] do
      []
    else
      warnings = []

      warnings =
        if AlexClaw.Config.get("telegram.node") in [nil, ""] and
             AlexClaw.Config.get("telegram.enabled") in [true, "true"] and
             AlexClaw.Config.get("telegram.bot_token") not in [nil, ""] do
          ["Telegram gateway paused — assign a node in Config > Telegram > telegram.node" | warnings]
        else
          warnings
        end

      warnings =
        if AlexClaw.Config.get("discord.node") in [nil, ""] and
             AlexClaw.Config.get("discord.enabled") in [true, "true"] do
          ["Discord gateway paused — assign a node in Config > Discord > discord.node" | warnings]
        else
          warnings
        end

      warnings
    end
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
      <div class="text-sm text-gray-500">{@title}</div>
      <div class="text-2xl font-bold text-white mt-1">{@value}</div>
    </div>
    """
  end
end
