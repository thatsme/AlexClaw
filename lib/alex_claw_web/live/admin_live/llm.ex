defmodule AlexClawWeb.AdminLive.LLM do
  @moduledoc "LiveView page for configuring built-in and custom LLM providers."

  use Phoenix.LiveView

  alias AlexClaw.Config
  alias AlexClaw.LLM

  @builtin_providers [
    %{id: :gemini_flash, name: "Gemini Flash", tier: :light, limit: "250 req/day", keys: ["llm.gemini_api_key"]},
    %{id: :gemini_pro, name: "Gemini Pro", tier: :medium, limit: "50 req/day", keys: ["llm.gemini_api_key"]},
    %{id: :haiku, name: "Claude Haiku", tier: :light, limit: "1000 req/day", keys: ["llm.anthropic_api_key"]},
    %{id: :sonnet, name: "Claude Sonnet", tier: :medium, limit: "5 req/day", keys: ["llm.anthropic_api_key"]},
    %{id: :opus, name: "Claude Opus", tier: :heavy, limit: "paid", keys: ["llm.anthropic_api_key"]},
    %{id: :ollama, name: "Ollama (local)", tier: :local, limit: "unlimited", keys: ["llm.ollama_enabled", "llm.ollama_host", "llm.ollama_model"]},
    %{id: :lm_studio, name: "LM Studio (local)", tier: :local, limit: "unlimited", keys: ["llm.lmstudio_enabled", "llm.lmstudio_host", "llm.lmstudio_model"]}
  ]

  @provider_types ~w(openai_compatible ollama gemini anthropic custom)
  @tiers ~w(light medium heavy local)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(10_000, :refresh_usage)

    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh_usage, socket) do
    {:noreply, assign(socket, builtins: build_builtins())}
  end

  @impl true
  def handle_event("edit_builtin", %{"id" => id}, socket) do
    provider_id = String.to_existing_atom(id)
    current = socket.assigns.editing_builtin

    editing =
      if current && current.id == provider_id,
        do: nil,
        else: Enum.find(@builtin_providers, &(&1.id == provider_id))

    {:noreply, assign(socket, editing_builtin: editing)}
  end

  @impl true
  def handle_event("save_builtin", params, socket) do
    editing = socket.assigns.editing_builtin

    Enum.each(editing.keys, fn key ->
      save_config_value(key, params[key])
    end)

    {:noreply,
     socket
     |> put_flash(:info, "#{editing.name} updated")
     |> assign(editing_builtin: nil)
     |> assign_data()}
  end

  @impl true
  def handle_event("cancel_builtin", _, socket) do
    {:noreply, assign(socket, editing_builtin: nil)}
  end

  @impl true
  def handle_event("test_provider", %{"provider" => provider_str}, socket) do
    provider = String.to_existing_atom(provider_str)

    result =
      case LLM.complete("Reply with only: OK", tier: tier_for(provider)) do
        {:ok, text} -> "OK: #{String.slice(text, 0, 50)}"
        {:error, reason} -> "Error: #{inspect(reason)}"
      end

    {:noreply, put_flash(socket, :info, "#{provider}: #{result}")}
  end

  @impl true
  def handle_event("toggle_custom_form", _, socket) do
    {:noreply, assign(socket, show_custom_form: !socket.assigns.show_custom_form, editing_custom: nil)}
  end

  @impl true
  def handle_event("edit_custom", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, provider_id} ->
        case LLM.get_provider(provider_id) do
          {:ok, provider} ->
            {:noreply, assign(socket, editing_custom: provider, show_custom_form: true)}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Provider not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_custom", params, socket) do
    attrs = %{
      name: params["name"],
      type: params["type"],
      tier: params["tier"],
      host: params["host"],
      model: params["model"],
      api_key: blank_to_nil(params["api_key"]),
      daily_limit: parse_int(params["daily_limit"]),
      enabled: params["enabled"] == "true"
    }

    result =
      case socket.assigns.editing_custom do
        nil -> LLM.create_provider(attrs)
        provider -> LLM.update_provider(provider, drop_blank_api_key(attrs, provider))
      end

    case result do
      {:ok, _} ->
        action = if socket.assigns.editing_custom, do: "updated", else: "added"

        {:noreply,
         socket
         |> put_flash(:info, "Provider #{action}")
         |> assign(show_custom_form: false, editing_custom: nil)
         |> assign_data()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("delete_custom", %{"id" => id}, socket) do
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
  def handle_event("cancel_custom", _, socket) do
    {:noreply, assign(socket, show_custom_form: false, editing_custom: nil)}
  end

  defp assign_data(socket) do
    assign(socket,
      page_title: "LLM Providers",
      builtins: build_builtins(),
      customs: LLM.list_custom_providers(),
      editing_builtin: nil,
      editing_custom: nil,
      show_custom_form: false,
      provider_types: @provider_types,
      tiers: @tiers
    )
  end

  defp build_builtins do
    today = Date.utc_today()

    Enum.map(@builtin_providers, fn p ->
      count =
        case :ets.lookup(:alexclaw_llm_usage, {p.id, today}) do
          [{_, c}] -> c
          [] -> 0
        end

      p
      |> Map.put(:usage_today, count)
      |> Map.put(:configured, builtin_configured?(p.keys))
    end)
  end

  defp builtin_configured?(keys) do
    Enum.all?(keys, fn
      key when key in ["llm.ollama_enabled", "llm.lmstudio_enabled"] ->
        Config.get(key) == true

      key ->
        val = Config.get(key)
        is_binary(val) and val != ""
    end)
  end

  defp save_config_value(key, nil), do: key
  defp save_config_value(key, "") when key in ["llm.gemini_api_key", "llm.anthropic_api_key"], do: key

  defp save_config_value(key, value) when key in ["llm.ollama_enabled", "llm.lmstudio_enabled"] do
    Config.set(key, value == "true", type: "boolean", category: "llm")
  end

  defp save_config_value(key, value), do: Config.set(key, value, type: "string", category: "llm")

  defp config_value(key) when key in ["llm.ollama_enabled", "llm.lmstudio_enabled"] do
    Config.get(key) == true
  end

  defp config_value(key), do: Config.get(key) || ""

  defp secret_key?(key), do: key in ["llm.gemini_api_key", "llm.anthropic_api_key"]
  defp boolean_key?(key), do: key in ["llm.ollama_enabled", "llm.lmstudio_enabled"]
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

  defp label_for("llm.gemini_api_key"), do: "API Key"
  defp label_for("llm.anthropic_api_key"), do: "API Key"
  defp label_for("llm.ollama_enabled"), do: "Enabled"
  defp label_for("llm.ollama_host"), do: "Host"
  defp label_for("llm.ollama_model"), do: "Model"
  defp label_for("llm.lmstudio_enabled"), do: "Enabled"
  defp label_for("llm.lmstudio_host"), do: "Host"
  defp label_for("llm.lmstudio_model"), do: "Model"
  defp label_for(key), do: key

  defp tier_for(:gemini_flash), do: :light
  defp tier_for(:gemini_pro), do: :medium
  defp tier_for(:haiku), do: :light
  defp tier_for(:sonnet), do: :medium
  defp tier_for(:opus), do: :heavy
  defp tier_for(:ollama), do: :local
  defp tier_for(:lm_studio), do: :local

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <h1 class="text-2xl font-bold text-white">LLM Providers</h1>

      <div>
        <h2 class="text-lg font-semibold text-gray-300 mb-3">Built-in</h2>
        <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
          <table class="w-full">
            <thead class="bg-gray-800">
              <tr>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Provider</th>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Tier</th>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Limit</th>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Usage</th>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Status</th>
                <th class="px-4 py-3 text-right text-xs text-gray-400 uppercase">Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for p <- @builtins do %>
                <tr class="border-t border-gray-800">
                  <td class="px-4 py-3 text-sm font-semibold text-white">{p.name}</td>
                  <td class="px-4 py-3">
                    <span class={tier_badge_class(p.tier)}>{p.tier}</span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-400">{p.limit}</td>
                  <td class="px-4 py-3 text-sm font-mono text-claw-500">{p.usage_today}</td>
                  <td class="px-4 py-3">
                    <span :if={p.configured} class="text-xs px-2 py-1 rounded bg-green-900 text-green-300">configured</span>
                    <span :if={!p.configured} class="text-xs px-2 py-1 rounded bg-red-900 text-red-300">not set</span>
                  </td>
                  <td class="px-4 py-3 text-right space-x-2">
                    <button phx-click="edit_builtin" phx-value-id={p.id}
                      class="text-xs text-claw-500 hover:text-claw-400">
                      {if @editing_builtin && @editing_builtin.id == p.id, do: "Close", else: "Edit"}
                    </button>
                    <button phx-click="test_provider" phx-value-provider={p.id}
                      class="text-xs text-green-500 hover:text-green-400">Test</button>
                  </td>
                </tr>
                <tr :if={@editing_builtin && @editing_builtin.id == p.id} class="border-t border-gray-700">
                  <td colspan="6" class="px-4 py-4">
                    <form phx-submit="save_builtin" class="space-y-3">
                      <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
                        <div :for={key <- @editing_builtin.keys}>
                          <label class="block text-xs text-gray-500 mb-1">{label_for(key)}</label>
                          <input :if={secret_key?(key)}
                            type="password" name={key}
                            placeholder={mask_value(config_value(key))}
                            autocomplete="off"
                            class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
                          <select :if={boolean_key?(key)}
                            name={key}
                            class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                            <option value="true" selected={config_value(key) == true}>Enabled</option>
                            <option value="false" selected={config_value(key) != true}>Disabled</option>
                          </select>
                          <input :if={!secret_key?(key) && !boolean_key?(key)}
                            type="text" name={key}
                            value={config_value(key)}
                            class="w-full bg-gray-900 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
                        </div>
                      </div>
                      <div class="flex space-x-2">
                        <button type="submit" class="px-3 py-1.5 bg-green-700 hover:bg-green-600 text-white text-sm rounded transition">Save</button>
                        <button type="button" phx-click="cancel_builtin" class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-white text-sm rounded transition">Cancel</button>
                      </div>
                    </form>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <div>
        <div class="flex justify-between items-center mb-3">
          <h2 class="text-lg font-semibold text-gray-300">Custom Providers</h2>
          <button phx-click="toggle_custom_form" class="px-4 py-2 bg-claw-700 hover:bg-claw-600 text-white text-sm rounded transition">
            {if @show_custom_form && !@editing_custom, do: "Cancel", else: "Add Provider"}
          </button>
        </div>

        <div :if={@show_custom_form} class="bg-gray-900 rounded-lg border border-gray-800 p-6 mb-4">
          <h3 class="text-md font-semibold text-white mb-3">{if @editing_custom, do: "Edit Provider", else: "New Provider"}</h3>
          <form phx-submit="save_custom" class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div>
              <label class="block text-xs text-gray-500 mb-1">Name</label>
              <input type="text" name="name" required value={if @editing_custom, do: @editing_custom.name, else: ""}
                class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Type</label>
              <select name="type" class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                <option :for={t <- @provider_types} value={t} selected={@editing_custom && @editing_custom.type == t}>{t}</option>
              </select>
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Tier</label>
              <select name="tier" class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                <option :for={t <- @tiers} value={t} selected={@editing_custom && @editing_custom.tier == t}>{t}</option>
              </select>
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Host / Base URL</label>
              <input type="text" name="host" required placeholder="http://localhost:1234"
                value={if @editing_custom, do: @editing_custom.host, else: ""}
                class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Model</label>
              <input type="text" name="model" required placeholder="model-name"
                value={if @editing_custom, do: @editing_custom.model, else: ""}
                class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">API Key</label>
              <input type="password" name="api_key"
                placeholder={if @editing_custom && @editing_custom.api_key, do: mask_value(@editing_custom.api_key), else: "optional"}
                autocomplete="off"
                class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Daily Limit</label>
              <input type="number" name="daily_limit" placeholder="unlimited"
                value={if @editing_custom && @editing_custom.daily_limit, do: @editing_custom.daily_limit, else: ""}
                class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Enabled</label>
              <select name="enabled" class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-white text-sm">
                <option value="true" selected={!@editing_custom || @editing_custom.enabled}>Yes</option>
                <option value="false" selected={@editing_custom && !@editing_custom.enabled}>No</option>
              </select>
            </div>
            <div class="flex items-end space-x-2">
              <button type="submit" class="px-3 py-1.5 bg-green-700 hover:bg-green-600 text-white text-sm rounded transition">
                {if @editing_custom, do: "Update", else: "Create"}
              </button>
              <button type="button" phx-click="cancel_custom" class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-white text-sm rounded transition">Cancel</button>
            </div>
          </form>
        </div>

        <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
          <table class="w-full">
            <thead class="bg-gray-800">
              <tr>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Name</th>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Type</th>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Tier</th>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Host</th>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Model</th>
                <th class="px-4 py-3 text-left text-xs text-gray-400 uppercase">Status</th>
                <th class="px-4 py-3 text-right text-xs text-gray-400 uppercase">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@customs == []} class="border-t border-gray-800">
                <td colspan="7" class="px-4 py-8 text-center text-gray-500">No custom providers. Add one to use local or third-party LLMs.</td>
              </tr>
              <tr :for={cp <- @customs} class="border-t border-gray-800">
                <td class="px-4 py-3 text-sm font-semibold text-white">{cp.name}</td>
                <td class="px-4 py-3">
                  <span class="text-xs px-2 py-0.5 rounded bg-gray-800 text-gray-400 font-mono">{cp.type}</span>
                </td>
                <td class="px-4 py-3">
                  <span class={tier_badge_class(String.to_existing_atom(cp.tier))}>{cp.tier}</span>
                </td>
                <td class="px-4 py-3 text-sm text-gray-400 font-mono truncate max-w-xs">{cp.host}</td>
                <td class="px-4 py-3 text-sm text-gray-400">{cp.model}</td>
                <td class="px-4 py-3">
                  <span :if={cp.enabled} class="text-xs px-2 py-1 rounded bg-green-900 text-green-300">enabled</span>
                  <span :if={!cp.enabled} class="text-xs px-2 py-1 rounded bg-gray-800 text-gray-500">disabled</span>
                </td>
                <td class="px-4 py-3 text-right space-x-2">
                  <button phx-click="edit_custom" phx-value-id={cp.id}
                    class="text-xs text-claw-500 hover:text-claw-400">Edit</button>
                  <button phx-click="delete_custom" phx-value-id={cp.id}
                    data-confirm="Delete this provider?"
                    class="text-xs text-red-500 hover:text-red-400">Delete</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp tier_badge_class(tier) do
    base = "text-xs px-2 py-1 rounded font-mono"

    color =
      case tier do
        :light -> "bg-green-900 text-green-300"
        :medium -> "bg-yellow-900 text-yellow-300"
        :heavy -> "bg-red-900 text-red-300"
        :local -> "bg-purple-900 text-purple-300"
        _ -> "bg-gray-800 text-gray-400"
      end

    "#{base} #{color}"
  end
end
