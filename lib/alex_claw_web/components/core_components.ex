defmodule AlexClawWeb.CoreComponents do
  @moduledoc "Shared UI components such as flash notifications used across all pages."

  use Phoenix.Component

  attr(:flash, :map, required: true)

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div class="fixed top-4 right-4 z-50 space-y-2">
      <.flash :if={msg = Phoenix.Flash.get(@flash, :info)} kind={:info} message={msg} />
      <.flash :if={msg = Phoenix.Flash.get(@flash, :error)} kind={:error} message={msg} />
    </div>
    """
  end

  attr(:kind, :atom, required: true)
  attr(:message, :string, required: true)

  @spec flash(map()) :: Phoenix.LiveView.Rendered.t()
  def flash(assigns) do
    ~H"""
    <div class={[
      "px-4 py-3 rounded-lg text-sm shadow-lg",
      @kind == :info && "bg-claw-800 text-claw-100 border border-claw-600",
      @kind == :error && "bg-red-900 text-red-100 border border-red-700"
    ]}>
      {@message}
    </div>
    """
  end

  attr(:elevation, :map, required: true)
  attr(:unlockable, :boolean, default: true)

  @doc """
  The elevation state of the page: locked, unlocked, or unprotected.

  The third case is the loud one. With no second factor configured there is
  nothing for the gate to verify, so every change on the page is protected by
  the admin password alone, and the banner says exactly that rather than
  leaving the page looking guarded.
  """
  @spec elevation_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def elevation_bar(%{elevation: %{required?: false}} = assigns) do
    ~H"""
    <div class="bg-red-950 border border-red-800 text-red-200 text-sm rounded-lg px-4 py-3">
      <span class="font-semibold">2FA not configured</span>
      — admin changes are protected by password only.
      <span class="text-red-300">Set it up from a gateway with <code>/setup 2fa</code>.</span>
    </div>
    """
  end

  def elevation_bar(%{unlockable: false} = assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-700 text-gray-300 text-sm rounded-lg px-4 py-3">
      Changes on this page are challenged every time. An unlock earned elsewhere does not cover them.
    </div>
    """
  end

  def elevation_bar(%{elevation: %{elevated?: true}} = assigns) do
    ~H"""
    <div class="bg-emerald-950 border border-emerald-800 text-emerald-200 text-sm rounded-lg px-4 py-3">
      Editing unlocked until {format_deadline(@elevation.expires_at)} UTC.
    </div>
    """
  end

  def elevation_bar(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-700 text-gray-300 text-sm rounded-lg px-4 py-3 flex items-center justify-between gap-4">
      <span>Editing is locked. Changes here need a second factor.</span>
      <button
        phx-click="unlock_editing"
        class="px-3 py-1.5 bg-claw-700 hover:bg-claw-600 text-white text-xs rounded transition whitespace-nowrap"
      >
        Unlock editing
      </button>
    </div>
    """
  end

  defp format_deadline(nil), do: "—"

  defp format_deadline(unix_seconds) do
    unix_seconds
    |> DateTime.from_unix!()
    |> Calendar.strftime("%H:%M")
  end
end
