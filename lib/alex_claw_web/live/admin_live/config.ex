defmodule AlexClawWeb.AdminLive.Config do
  @moduledoc "LiveView page for viewing and editing key-value configuration settings."

  use Phoenix.LiveView


  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: AlexClaw.Config.subscribe()
    settings = AlexClaw.Config.list()

    {:ok,
     assign(socket,
       page_title: "Configuration",
       settings: settings,
       grouped: group_by_category(settings),
       collapsed: MapSet.new(),
       show_form: false,
       editing: nil
     )}
  end

  @impl true
  def handle_info({:config_changed, _key, _value}, socket) do
    settings = AlexClaw.Config.list()
    {:noreply, assign(socket, settings: settings, grouped: group_by_category(settings))}
  end

  @impl true
  def handle_event("toggle_form", _, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, editing: nil)}
  end

  @impl true
  def handle_event("save", params, socket) do
    key = params["key"]
    value = params["value"]

    # For sensitive fields, empty value keeps current UNLESS explicitly clearing
    if sensitive_key?(key) && (value == "" || is_nil(value)) && socket.assigns.editing && params["_clear"] != "true" do
      {:noreply,
       socket
       |> put_flash(:info, "Setting '#{key}' unchanged (submit empty to keep current, use Clear to erase)")
       |> assign(show_form: false, editing: nil)}
    else
      AlexClaw.Config.set(key, value || "",
        type: params["type"],
        description: params["description"],
        category: params["category"] |> to_string() |> String.trim() |> String.downcase()
      )

      {:noreply,
       socket
       |> put_flash(:info, "Setting '#{key}' saved")
       |> assign(settings: AlexClaw.Config.list(), grouped: group_by_category(AlexClaw.Config.list()), show_form: false, editing: nil)}
    end
  end

  @impl true
  def handle_event("edit", %{"id" => id_str}, socket) do
    case parse_id(id_str) do
      {:ok, id} ->
        setting = Enum.find(socket.assigns.settings, &(&1.id == id))
        {:noreply, assign(socket, editing: setting, show_form: true)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete", %{"key" => key}, socket) do
    AlexClaw.Config.delete(key)

    {:noreply,
     socket
     |> put_flash(:info, "Setting '#{key}' deleted")
     |> assign(settings: AlexClaw.Config.list(), grouped: group_by_category(AlexClaw.Config.list()))}
  end

  @impl true
  def handle_event("toggle_group", %{"group" => group}, socket) do
    collapsed =
      if MapSet.member?(socket.assigns.collapsed, group) do
        MapSet.delete(socket.assigns.collapsed, group)
      else
        MapSet.put(socket.assigns.collapsed, group)
      end

    {:noreply, assign(socket, collapsed: collapsed)}
  end

  @sensitive_patterns ~w(api_key token password secret)

  defp sensitive_key?(key) do
    key_down = String.downcase(key)
    Enum.any?(@sensitive_patterns, &String.contains?(key_down, &1))
  end

  defp mask_value(nil), do: ""
  defp mask_value(""), do: ""
  defp mask_value(value) when byte_size(value) <= 8, do: String.duplicate("*", String.length(value))
  defp mask_value(value) do
    String.slice(value, 0, 4) <> "********" <> String.slice(value, -4, 4)
  end

  defp display_value(setting) do
    if sensitive_key?(setting.key) do
      mask_value(setting.value)
    else
      String.slice(setting.value, 0, 80)
    end
  end

  @category_order ~w(telegram llm github auth skills prompts identity general)
  @category_labels %{
    "telegram" => "Telegram",
    "llm" => "LLM Providers",
    "github" => "GitHub",
    "auth" => "Authentication",
    "skills" => "Skills",
    "prompts" => "Prompts",
    "identity" => "Identity",
    "general" => "General"
  }

  defp group_by_category(settings) do
    groups = Enum.group_by(settings, &(&1.category || "general"))

    known = Enum.filter(@category_order, &Map.has_key?(groups, &1))
    extra = Map.keys(groups) |> Enum.reject(&(&1 in @category_order)) |> Enum.sort()

    (known ++ extra)
    |> Enum.map(fn cat -> {cat, Map.get(@category_labels, cat, String.capitalize(cat)), groups[cat]} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-start">
        <div>
          <h1 class="text-2xl font-bold text-white">Configuration</h1>
          <p class="text-xs text-gray-500 mt-1">Global defaults — can be overridden per workflow step via step config JSON</p>
        </div>
        <button phx-click="toggle_form" class="px-4 py-2 bg-claw-700 hover:bg-claw-600 text-white text-sm rounded transition">
          {if @show_form, do: "Cancel", else: "Add Setting"}
        </button>
      </div>

      <div :if={@show_form} class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <form phx-submit="save" class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label class="block text-sm text-gray-400 mb-1">Key</label>
            <input type="text" name="key" required value={@editing && @editing.key}
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Type</label>
            <select name="type" class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm">
              <option :for={t <- ~w(string integer float boolean json)} value={t} selected={@editing && @editing.type == t}>{t}</option>
            </select>
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Category</label>
            <input type="text" name="category" value={(@editing && @editing.category) || "general"}
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div>
            <label class="block text-sm text-gray-400 mb-1">Description</label>
            <input type="text" name="description" value={@editing && @editing.description}
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm" />
          </div>
          <div class="md:col-span-2">
            <label class="block text-sm text-gray-400 mb-1">Value</label>
            <%= if @editing && sensitive_key?(@editing.key) do %>
              <input type="password" name="value" placeholder={mask_value(@editing.value)}
                class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm font-mono" />
              <p class="text-xs text-gray-600 mt-1">Leave empty to keep current value, or enter a new one to replace it.</p>
              <input type="hidden" name="_clear" value="false" />
              <button type="submit" name="_clear" value="true"
                class="mt-2 px-3 py-1 bg-red-800 hover:bg-red-700 text-white text-xs rounded transition">
                Clear value
              </button>
            <% else %>
              <textarea name="value" rows="3"
                class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-white text-sm font-mono">{@editing && @editing.value}</textarea>
            <% end %>
          </div>
          <div class="md:col-span-2">
            <button type="submit" class="px-4 py-2 bg-green-700 hover:bg-green-600 text-white text-sm rounded transition">
              Save
            </button>
          </div>
        </form>
      </div>

      <div :if={@settings == []} class="bg-gray-900 rounded-lg border border-gray-800 p-6 text-center text-gray-500 text-sm">
        No settings configured yet.
      </div>

      <div :for={{cat, label, items} <- @grouped} class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
        <button phx-click="toggle_group" phx-value-group={cat}
          class="w-full flex items-center justify-between px-4 py-3 bg-gray-800 hover:bg-gray-750 transition cursor-pointer text-left">
          <div class="flex items-center gap-3">
            <span class={"text-xs transition-transform " <> if(MapSet.member?(@collapsed, cat), do: "-rotate-90", else: "rotate-0")}>
              &#9660;
            </span>
            <span class="text-sm font-semibold text-white uppercase tracking-wide">{label}</span>
            <span class="text-xs text-gray-500">{length(items)} settings</span>
          </div>
        </button>

        <table :if={!MapSet.member?(@collapsed, cat)} class="w-full table-fixed">
          <thead>
            <tr class="border-t border-gray-800">
              <th class="w-[30%] px-4 py-2 text-left text-xs text-gray-500 uppercase">Key</th>
              <th class="w-[35%] px-4 py-2 text-left text-xs text-gray-500 uppercase">Value</th>
              <th class="w-[10%] px-4 py-2 text-left text-xs text-gray-500 uppercase">Type</th>
              <th class="w-[25%] px-4 py-2 text-right text-xs text-gray-500 uppercase">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={setting <- items} class="border-t border-gray-800/50 hover:bg-gray-800/30">
              <td class="px-4 py-2.5 text-sm font-mono text-white truncate" title={setting.key}>{setting.key}</td>
              <td class="px-4 py-2.5 text-sm font-mono text-gray-300 truncate" title={if(!sensitive_key?(setting.key), do: setting.value, else: "")}>
                <span :if={sensitive_key?(setting.key)} class="text-gray-500">{display_value(setting)}</span>
                <span :if={!sensitive_key?(setting.key)}>{display_value(setting)}</span>
              </td>
              <td class="px-4 py-2.5">
                <span class="text-xs px-2 py-0.5 rounded bg-gray-800 text-gray-400">{setting.type}</span>
              </td>
              <td class="px-4 py-2.5 text-right space-x-2 whitespace-nowrap">
                <span class="text-xs text-gray-600 mr-2" title={setting.description}>{truncate_desc(setting.description)}</span>
                <button phx-click="edit" phx-value-id={setting.id} class="text-xs text-claw-500 hover:text-claw-400">Edit</button>
                <button phx-click="delete" phx-value-key={setting.key}
                  data-confirm="Delete this setting?"
                  class="text-xs text-red-500 hover:text-red-400">Del</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp truncate_desc(nil), do: ""
  defp truncate_desc(desc) when byte_size(desc) > 40, do: String.slice(desc, 0, 37) <> "..."
  defp truncate_desc(desc), do: desc

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end
end
