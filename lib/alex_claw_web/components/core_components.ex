defmodule AlexClawWeb.CoreComponents do
  @moduledoc "Shared UI components such as flash notifications used across all pages."

  use Phoenix.Component

  attr(:flash, :map, required: true)

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" class="fixed top-4 right-4 z-50 space-y-2">
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
  The elevation state of the page: unconfigured, locked, unlocked, or asking.

  The code field is the ordinary way in — the authenticator is the second
  factor, and typing the code where you already are is what people expect. The
  gateway challenge sits beside it for operators who would rather have the
  prompt arrive on another device.
  """
  @spec elevation_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def elevation_bar(%{elevation: %{configured?: false}} = assigns) do
    ~H"""
    <div class="bg-red-950 border border-red-800 text-red-200 text-sm rounded-lg px-4 py-3">
      <span class="font-semibold">Read-only — 2FA is not configured.</span>
      Admin changes require a second factor. Set it up under
      <.link navigate="/services" class="underline">Services → Two-factor authentication</.link>.
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

  def elevation_bar(%{elevation: %{lock: {:locked, kind, until}}} = assigns) do
    assigns = assign(assigns, kind: kind, until: until)

    ~H"""
    <div class="bg-amber-950 border border-amber-800 text-amber-200 text-sm rounded-lg px-4 py-3">
      <span class="font-semibold">Code entry locked</span>
      after too many wrong codes{scope(@kind)}. Try again after {format_deadline(@until)} UTC.
    </div>
    """
  end

  def elevation_bar(%{elevation: %{entry_open?: true}} = assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-700 text-gray-300 text-sm rounded-lg px-4 py-3 space-y-3">
      <form phx-submit="submit_code" class="flex items-center gap-3 flex-wrap">
        <label for="elevation-code" class="whitespace-nowrap">
          Code from your authenticator
        </label>
        <input
          type="text"
          id="elevation-code"
          name="code"
          inputmode="numeric"
          autocomplete="one-time-code"
          autofocus
          class="bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-white text-sm w-40 tracking-widest"
        />
        <button
          type="submit"
          class="px-3 py-1.5 bg-claw-700 hover:bg-claw-600 text-white text-xs rounded transition"
        >
          Unlock
        </button>
        <button
          type="button"
          phx-click="cancel_code"
          class="px-3 py-1.5 bg-gray-800 hover:bg-gray-700 text-gray-300 text-xs rounded transition"
        >
          Cancel
        </button>
        <button
          type="button"
          phx-click="request_gateway_code"
          class="text-xs text-gray-400 hover:text-gray-200 underline bg-transparent border-none cursor-pointer"
        >
          Send the prompt to my gateway instead
        </button>
      </form>
      <p :if={@elevation.message} class="text-red-300 text-xs">{@elevation.message}</p>
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

  attr(:action_code, :map, required: true)

  @doc """
  The code field for one action waiting to be confirmed.

  Separate from `elevation_bar/1` because it confirms a single thing rather
  than opening a window: the description says what is about to happen, and
  nothing else on the page becomes editable.
  """
  @spec action_code_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def action_code_bar(%{action_code: %{open?: false}} = assigns) do
    ~H"""
    """
  end

  def action_code_bar(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-claw-700 text-gray-200 text-sm rounded-lg px-4 py-3 space-y-3">
      <p>
        <span class="font-semibold">Confirm:</span> {@action_code.description}
      </p>
      <form phx-submit="submit_action_code" class="flex items-center gap-3 flex-wrap">
        <label for="action-code" class="whitespace-nowrap">Code from your authenticator</label>
        <input
          type="text"
          id="action-code"
          name="code"
          inputmode="numeric"
          autocomplete="one-time-code"
          autofocus
          class="bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-white text-sm w-40 tracking-widest"
        />
        <button
          type="submit"
          class="px-3 py-1.5 bg-claw-700 hover:bg-claw-600 text-white text-xs rounded transition"
        >
          Confirm
        </button>
        <button
          type="button"
          phx-click="cancel_action_code"
          class="px-3 py-1.5 bg-gray-800 hover:bg-gray-700 text-gray-300 text-xs rounded transition"
        >
          Cancel
        </button>
        <span class="text-xs text-gray-500">or answer the prompt on your gateway</span>
      </form>
      <p :if={@action_code.message} class="text-red-300 text-xs">{@action_code.message}</p>
    </div>
    """
  end

  defp scope(:session), do: " from this session"
  defp scope(:instance), do: " across sessions"

  defp format_deadline(nil), do: "—"

  defp format_deadline(unix_seconds) do
    unix_seconds
    |> DateTime.from_unix!()
    |> Calendar.strftime("%H:%M")
  end
end
