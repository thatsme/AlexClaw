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
        category: params["category"] |> to_string() |> String.trim() |> String.downcase(),
        sensitive: sensitive_key?(key)
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
    if setting.sensitive || sensitive_key?(setting.key) do
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
