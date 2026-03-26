defmodule AlexClawWeb.CoreComponents do
  @moduledoc "Shared UI components such as flash notifications used across all pages."

  use Phoenix.Component

  attr :flash, :map, required: true

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div class="fixed top-4 right-4 z-50 space-y-2">
      <.flash :if={msg = Phoenix.Flash.get(@flash, :info)} kind={:info} message={msg} />
      <.flash :if={msg = Phoenix.Flash.get(@flash, :error)} kind={:error} message={msg} />
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :message, :string, required: true

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
end
