defmodule AlexClawWeb.AdminLive.Logs do
  @moduledoc "LiveView page for real-time log viewing with severity filtering."

  use Phoenix.LiveView

  alias AlexClaw.LogBuffer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(3_000, :refresh)
    end

    {:ok,
     assign(socket,
       page_title: "Logs",
       filter: nil,
       entries: LogBuffer.recent(limit: 100),
       counts: LogBuffer.counts()
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    filter = socket.assigns.filter
    opts = if filter, do: [severity: filter, limit: 100], else: [limit: 100]

    {:noreply,
     assign(socket,
       entries: LogBuffer.recent(opts),
       counts: LogBuffer.counts()
     )}
  end

  @impl true
  def handle_event("clear", _, socket) do
    LogBuffer.clear()

    {:noreply,
     assign(socket,
       entries: [],
       counts: %{critical: 0, high: 0, moderate: 0, low: 0, circuit_breaker: 0}
     )}
  end

  def handle_event("filter", %{"severity" => "all"}, socket) do
    {:noreply,
     assign(socket,
       filter: nil,
       entries: LogBuffer.recent(limit: 100)
     )}
  end

  def handle_event("filter", %{"severity" => severity}, socket) do
    severity = String.to_existing_atom(severity)

    {:noreply,
     assign(socket,
       filter: severity,
       entries: LogBuffer.recent(severity: severity, limit: 100)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold text-white">Logs</h1>
        <div class="flex items-center gap-4">
          <span class="text-sm text-gray-500">{length(@entries)} entries</span>
          <button phx-click="clear" data-confirm="Clear all logs?" class="px-3 py-1.5 rounded text-sm font-medium bg-red-900/50 text-red-400 hover:bg-red-900 transition-colors">
            Clear
          </button>
        </div>
      </div>

      <div class="flex gap-2">
        <.filter_btn severity="all" label="All" active={@filter == nil} />
        <.filter_btn severity="critical" label={"Critical (#{@counts.critical})"} active={@filter == :critical} color="red" />
        <.filter_btn severity="high" label={"High (#{@counts.high})"} active={@filter == :high} color="orange" />
        <.filter_btn severity="moderate" label={"Moderate (#{@counts.moderate})"} active={@filter == :moderate} color="yellow" />
        <.filter_btn severity="low" label={"Low (#{@counts.low})"} active={@filter == :low} color="gray" />
        <.filter_btn severity="circuit_breaker" label={"Circuit Breaker (#{@counts.circuit_breaker})"} active={@filter == :circuit_breaker} color="blue" />
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
        <div :if={@entries == []} class="p-8 text-center text-gray-500">No log entries.</div>
        <div :for={entry <- @entries} class={"flex gap-4 px-4 py-2 border-b border-gray-800/50 last:border-0 #{row_bg(entry.severity)}"}>
          <div class="flex-shrink-0 w-20 text-xs text-gray-500 font-mono pt-0.5">
            {AlexClawWeb.TimeHelpers.format_datetime(entry.timestamp)}
          </div>
          <div class="flex-shrink-0" title={entry[:workflow]}>
            <.severity_badge severity={entry.severity} />
          </div>
          <div class="flex-1 min-w-0">
            <p class="text-sm text-gray-300 font-mono break-all">{String.slice(entry.message, 0, 500)}</p>
            <p :if={entry.module} class="text-xs text-gray-600 mt-0.5">{inspect(entry.module)}</p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp filter_btn(assigns) do
    assigns = assign_new(assigns, :color, fn -> "blue" end)

    ~H"""
    <button
      phx-click="filter"
      phx-value-severity={@severity}
      class={"px-3 py-1.5 rounded text-sm font-medium transition-colors " <>
        if(@active,
          do: "bg-claw-600 text-white",
          else: "bg-gray-800 text-gray-400 hover:text-white hover:bg-gray-700"
        )}
    >
      {@label}
    </button>
    """
  end

  defp severity_badge(assigns) do
    {bg, text} =
      case assigns.severity do
        :critical -> {"bg-red-900/50 text-red-400", "CRIT"}
        :high -> {"bg-orange-900/50 text-orange-400", "HIGH"}
        :moderate -> {"bg-yellow-900/50 text-yellow-400", "MOD"}
        :low -> {"bg-gray-800 text-gray-500", "LOW"}
        :circuit_breaker -> {"bg-blue-900/50 text-blue-400", "CB"}
      end

    assigns = assign(assigns, bg: bg, text: text)

    ~H"""
    <span class={"px-2 py-0.5 rounded text-xs font-bold #{@bg}"}>{@text}</span>
    """
  end

  defp row_bg(:critical), do: "bg-red-950/20"
  defp row_bg(:high), do: "bg-orange-950/10"
  defp row_bg(:circuit_breaker), do: "bg-blue-950/10"
  defp row_bg(_), do: ""
end
