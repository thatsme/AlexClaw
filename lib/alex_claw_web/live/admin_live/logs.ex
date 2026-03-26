defmodule AlexClawWeb.AdminLive.Logs do
  @moduledoc "LiveView page for real-time log viewing with severity filtering."

  use Phoenix.LiveView

  alias AlexClaw.LogBuffer

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
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
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
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
