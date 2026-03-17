defmodule AlexClawWeb.AdminLive.LLM do
  @moduledoc "LiveView page for configuring LLM providers (all stored in DB)."

  use Phoenix.LiveView

  alias AlexClaw.LLM

  @provider_types ~w(openai_compatible ollama gemini anthropic custom)
  @tiers ~w(light medium heavy local)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(10_000, :refresh_usage)

    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh_usage, socket) do
    {:noreply, assign(socket, providers: build_providers())}
  end

  @impl true
  def handle_event("toggle_form", _, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, editing: nil)}
  end

  @impl true
  def handle_event("edit_provider", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, provider_id} ->
        case LLM.get_provider(provider_id) do
          {:ok, provider} ->
            {:noreply, assign(socket, editing: provider, show_form: true)}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Provider not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_provider", params, socket) do
    attrs = %{
      name: params["name"],
      type: params["type"],
      tier: params["tier"],
      host: blank_to_nil(params["host"]),
      model: params["model"],
      api_key: blank_to_nil(params["api_key"]),
      daily_limit: parse_int(params["daily_limit"]),
      priority: parse_int(params["priority"]) || 100,
      enabled: params["enabled"] == "true"
    }

    result =
      case socket.assigns.editing do
        nil -> LLM.create_provider(attrs)
        provider -> LLM.update_provider(provider, drop_blank_api_key(attrs, provider))
      end

    case result do
      {:ok, _} ->
        action = if socket.assigns.editing, do: "updated", else: "added"

        {:noreply,
         socket
         |> put_flash(:info, "Provider #{action}")
         |> assign(show_form: false, editing: nil)
         |> assign_data()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("delete_provider", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, provider_id} ->
        case LLM.get_provider(provider_id) do
          {:ok, provider} ->
            {:ok, _} = LLM.delete_provider(provider)

            {:noreply,
             socket
             |> put_flash(:info, "Provider deleted")
             |> assign_data()}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Provider not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_form", _, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil)}
  end

  @impl true
  def handle_event("test_provider", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, provider_id} ->
        case LLM.get_provider(provider_id) do
          {:ok, provider} ->
            result =
              case LLM.complete("Reply with only: OK", provider: provider.name) do
                {:ok, text} -> "OK: #{String.slice(text, 0, 50)}"
                {:error, reason} -> "Error: #{inspect(reason)}"
              end

            {:noreply, put_flash(socket, :info, "#{provider.name}: #{result}")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Provider not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  defp assign_data(socket) do
    assign(socket,
      page_title: "LLM Providers",
      providers: build_providers(),
      editing: nil,
      show_form: false,
      provider_types: @provider_types,
      tiers: @tiers
    )
  end

  defp build_providers do
    LLM.list_providers()
    |> Enum.map(fn p ->
      Map.put(p, :usage_today, LLM.usage_today(p.id))
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(val), do: val

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp drop_blank_api_key(%{api_key: nil} = attrs, _provider), do: Map.delete(attrs, :api_key)
  defp drop_blank_api_key(attrs, _provider), do: attrs

  defp mask_value(val) when is_binary(val) and byte_size(val) > 8 do
    String.slice(val, 0, 4) <> "********" <> String.slice(val, -4, 4)
  end

  defp mask_value(_), do: ""

  defp format_limit(nil), do: "unlimited"
  defp format_limit(n), do: "#{n}/day"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold text-white">LLM Providers</h1>
        <button phx-click="toggle_form" class="px-4 py-2 bg-claw-700 hover:bg-claw-600 text-white text-sm rounded transition">
          {if @show_form && !@editing, do: "Cancel", else: "Add Provider"}
        </button>
      </div>

      <div :if={@show_form} class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <h3 class="text-md font-semibold text-white mb-3">{if @editing, do: "Edit Provider", else: "New Provider"}</h3>
        <form phx-submit="save_provider" class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div>
            <label class="block text-xs text-gray-500 mb-1">Name</label>
            <input type="text" name="name" required value={if @editing, do: @editing.name, else: ""}
              class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">Type</label>
            <select name="type" class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
              <option :for={t <- @provider_types} value={t} selected={@editing && @editing.type == t}>{t}</option>
            </select>
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">Tier</label>
            <select name="tier" class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
              <option :for={t <- @tiers} value={t} selected={@editing && @editing.tier == t}>{t}</option>
            </select>
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">Host / Base URL</label>
            <input type="text" name="host" placeholder="http://localhost:1234 (optional for cloud)"
              value={if @editing, do: @editing.host, else: ""}
              class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">Model</label>
            <input type="text" name="model" required placeholder="model-name"
              value={if @editing, do: @editing.model, else: ""}
              class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">API Key</label>
            <input type="password" name="api_key"
              placeholder={if @editing && @editing.api_key, do: mask_value(@editing.api_key), else: "optional"}
              autocomplete="off"
              class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">Daily Limit</label>
            <input type="number" name="daily_limit" placeholder="unlimited"
              value={if @editing && @editing.daily_limit, do: @editing.daily_limit, else: ""}
              class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">Priority</label>
            <input type="number" name="priority" placeholder="100"
              value={if @editing, do: @editing.priority, else: "100"}
              class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
            <span class="text-xs text-gray-600">Lower = preferred</span>
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">Enabled</label>
            <select name="enabled" class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
              <option value="true" selected={!@editing || @editing.enabled}>Yes</option>
              <option value="false" selected={@editing && !@editing.enabled}>No</option>
            </select>
          </div>
          <div class="flex items-end space-x-2">
            <button type="submit" class="px-3 py-1.5 bg-green-700 hover:bg-green-600 text-white text-sm rounded transition">
              {if @editing, do: "Update", else: "Create"}
            </button>
            <button type="button" phx-click="cancel_form" class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-white text-sm rounded transition">Cancel</button>
          </div>
        </form>
      </div>

      <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
        <table class="w-full">
          <thead class="bg-gray-800">
            <tr>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Provider</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Type</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Tier</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Model</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Limit</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Usage</th>
              <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Status</th>
              <th class="px-4 py-3 text-right text-xs text-gray-400 uppercase">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@providers == []} class="border-t border-gray-800">
              <td colspan="8" class="px-4 py-8 text-center text-gray-500">No providers configured.</td>
            </tr>
            <tr :for={p <- @providers} class="border-t border-gray-800">
              <td class="px-4 py-3 text-sm font-semibold text-white">{p.name}</td>
              <td class="px-4 py-3">
                <span class="text-xs px-2 py-0.5 rounded bg-gray-800 text-gray-400 font-mono">{p.type}</span>
              </td>
              <td class="px-4 py-3">
                <span class={tier_badge_class(p.tier)}>{p.tier}</span>
              </td>
              <td class="px-4 py-3 text-sm text-gray-400 font-mono truncate max-w-xs">{p.model}</td>
              <td class="px-4 py-3 text-sm text-gray-400">{format_limit(p.daily_limit)}</td>
              <td class="px-4 py-3 text-sm font-mono text-claw-500">{p.usage_today}</td>
              <td class="px-4 py-3">
                <span :if={p.enabled} class="text-xs px-2 py-1 rounded bg-green-900 text-green-300">enabled</span>
                <span :if={!p.enabled} class="text-xs px-2 py-1 rounded bg-gray-800 text-gray-500">disabled</span>
              </td>
              <td class="px-4 py-3 text-right space-x-2">
                <button phx-click="edit_provider" phx-value-id={p.id}
                  class="text-xs text-claw-500 hover:text-claw-400">Edit</button>
                <button phx-click="test_provider" phx-value-id={p.id}
                  class="text-xs text-green-500 hover:text-green-400">Test</button>
                <button phx-click="delete_provider" phx-value-id={p.id}
                  data-confirm="Delete this provider?"
                  class="text-xs text-red-500 hover:text-red-400">Delete</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp tier_badge_class(tier) do
    base = "text-xs px-2 py-1 rounded font-mono"

    color =
      case tier do
        "light" -> "bg-green-900 text-green-300"
        "medium" -> "bg-yellow-900 text-yellow-300"
        "heavy" -> "bg-red-900 text-red-300"
        "local" -> "bg-purple-900 text-purple-300"
        _ -> "bg-gray-800 text-gray-400"
      end

    "#{base} #{color}"
  end
end
