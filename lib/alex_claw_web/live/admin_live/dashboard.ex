defmodule AlexClawWeb.AdminLive.Dashboard do
  @moduledoc "LiveView dashboard showing system uptime, memory usage, LLM stats, and recent activity."

  use Phoenix.LiveView


  @impl true
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
      version: Application.spec(:alex_claw, :vsn) |> to_string(),
      uptime: format_uptime(:erlang.statistics(:wall_clock) |> elem(0) |> div(1000)),
      memory_mb: div(memory_bytes, 1_048_576),
      skills_active: skill_children.active,
      skills_total: skill_children.workers,
      llm_usage: get_llm_usage(),
      google_status: AlexClaw.Google.TokenManager.status(),
      recent_memories: AlexClaw.Memory.recent(limit: 5)
    )
  end

  defp get_llm_usage do
    today = Date.utc_today()

    builtin =
      [:gemini_flash, :gemini_pro, :haiku, :sonnet, :opus, :ollama]
      |> Enum.map(fn model -> {model, ets_count({model, today})} end)

    custom =
      AlexClaw.LLM.list_custom_providers()
      |> Enum.map(fn p -> {{:custom, p.id}, ets_count({{:custom, p.id}, today}), p.name} end)
      |> Enum.reject(fn {_, c, _} -> c == 0 end)
      |> Enum.map(fn {_key, count, name} -> {name, count} end)

    builtin
    |> Enum.reject(fn {_, c} -> c == 0 end)
    |> Kernel.++(custom)
  end

  defp ets_count(key) do
    case :ets.lookup(:alexclaw_llm_usage, key) do
      [{_, c}] -> c
      [] -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold text-white">🦇 AlexClaw</h1>
        <span class="text-sm text-gray-500 font-mono">v{@version}</span>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-5 gap-4">
        <.stat_card title="Uptime" value={@uptime} />
        <.stat_card title="Memory" value={"#{@memory_mb} MB"} />
        <.stat_card title="Active Skills" value={@skills_active} />
        <.stat_card title="Total Workers" value={@skills_total} />
        <.stat_card title="Google" value={google_label(@google_status)} />
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <h2 class="text-lg font-semibold mb-4">LLM Usage Today</h2>
          <div :if={@llm_usage == []} class="text-gray-500 text-sm">No calls yet today.</div>
          <div :for={{model, count} <- @llm_usage} class="flex justify-between py-2 border-b border-gray-800 last:border-0">
            <span class="text-gray-300 font-mono text-sm">{model}</span>
            <span class="text-claw-500 font-bold">{count}</span>
          </div>
        </div>

        <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <h2 class="text-lg font-semibold mb-4">Recent Memories</h2>
          <div :if={@recent_memories == []} class="text-gray-500 text-sm">No memories yet.</div>
          <div :for={mem <- @recent_memories} class="py-2 border-b border-gray-800 last:border-0">
            <div class="flex items-center gap-2 mb-1">
              <span class="text-xs px-2 py-0.5 rounded bg-gray-800 text-gray-400">{mem.kind}</span>
              <span class="text-xs text-gray-600">{Calendar.strftime(mem.inserted_at, "%H:%M:%S")}</span>
            </div>
            <p class="text-sm text-gray-300 truncate">{String.slice(mem.content, 0, 120)}</p>
          </div>
        </div>
      </div>
    </div>
    """
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

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg border border-gray-800 p-4">
      <div class="text-sm text-gray-500">{@title}</div>
      <div class="text-2xl font-bold text-white mt-1">{@value}</div>
    </div>
    """
  end
end
