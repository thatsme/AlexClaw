defmodule AlexClawWeb.AdminLive.Config do
  @moduledoc "LiveView page for viewing and editing key-value configuration settings."

  use Phoenix.LiveView
  alias AlexClawWeb.Live.Elevation

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    socket = Elevation.assign_elevation(socket, session)
    if connected?(socket), do: AlexClaw.Config.subscribe()
    settings = AlexClaw.Config.list()

    {:ok,
     assign(socket,
       page_title: "Configuration",
       settings: settings,
       grouped: group_by_category(settings),
       collapsed: group_by_category(settings) |> Enum.map(&elem(&1, 0)) |> MapSet.new(),
       show_form: false,
       editing: nil,
       cluster_nodes: cluster_node_names()
     )}
  end

  @impl true
  def handle_info({:elevation, _state, _detail} = message, socket) do
    {:noreply, Elevation.handle_broadcast(socket, message)}
  end

  @impl true
  def handle_info({:config_changed, _key, _value}, socket) do
    settings = AlexClaw.Config.list()
    {:noreply, assign(socket, settings: settings, grouped: group_by_category(settings))}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_form", _, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, editing: nil)}
  end

  @impl true
  def handle_event("save", params, socket) do
    save_setting(gateway_managed?(params["key"]), params, socket)
  end

  @impl true
  def handle_event("edit", %{"id" => id_str}, socket) do
    case parse_id(id_str) do
      {:ok, id} ->
        setting = Enum.find(socket.assigns.settings, &(&1.id == id))
        {:noreply, assign(socket, editing: setting, show_form: false)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_edit", _, socket) do
    {:noreply, assign(socket, editing: nil)}
  end

  @impl true
  def handle_event("delete", %{"key" => key}, socket) do
    delete_setting(gateway_managed?(key), key, socket)
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

  def handle_event("unlock_editing", _params, socket) do
    Elevation.open_entry(socket)
  end

  def handle_event("submit_code", %{"code" => code}, socket) do
    Elevation.submit_code(socket, code)
  end

  def handle_event("cancel_code", _params, socket) do
    Elevation.close_entry(socket)
  end

  def handle_event("request_gateway_code", _params, socket) do
    Elevation.unlock(socket)
  end

  @sensitive_patterns ~w(api_key token password secret)

  # auth.totp.* is written only by the second-factor setup (Services, and
  # /setup 2fa on a gateway until 0.4.0 removes it). Elevation does not open it: the setting that decides whether
  # elevation is required at all must not be editable from behind that gate,
  # or the gate can be switched off through the page it protects.
  defp save_setting(true, params, socket) do
    {:noreply, put_flash(socket, :error, managed_message(params["key"]))}
  end

  defp save_setting(false, params, socket) do
    params
    |> keeps_secret?(socket)
    |> save_value(params, socket)
  end

  # For sensitive fields, an empty value keeps the current one unless the form
  # explicitly clears it. Nothing changes, so nothing is gated or audited.
  defp keeps_secret?(params, socket) do
    sensitive_key?(params["key"]) and params["value"] in ["", nil] and
      socket.assigns.editing != nil and params["_clear"] != "true"
  end

  defp save_value(true, params, socket) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       "Setting '#{params["key"]}' unchanged (submit empty to keep current, use Clear to erase)"
     )
     |> assign(show_form: false, editing: nil)}
  end

  defp save_value(false, params, socket) do
    key = params["key"]
    value = params["value"]

    Elevation.gated(socket, setting_change(params),
      write: fn ->
        with {:ok, _setting} <-
               AlexClaw.Config.persist(key, value || "",
                 type: params["type"],
                 description: params["description"],
                 category:
                   params["category"] |> to_string() |> String.trim() |> String.downcase(),
                 sensitive: sensitive_key?(key)
               ),
             {:ok, assigned} <- assign_gateway_node(key, value) do
          {:ok, [key | assigned]}
        end
      end,
      after_commit: fn keys -> Enum.each(keys, &AlexClaw.Config.publish/1) end,
      ok: fn socket, _keys ->
        settings = AlexClaw.Config.list()

        socket
        |> put_flash(:info, "Setting '#{key}' saved")
        |> assign(
          settings: settings,
          grouped: group_by_category(settings),
          show_form: false,
          editing: nil
        )
      end
    )
  end

  defp gateway_managed?(key) when is_binary(key), do: String.starts_with?(key, "auth.totp.")
  defp gateway_managed?(_key), do: false

  defp managed_message(key) do
    "#{key} is managed by two-factor setup — use the Services page"
  end

  defp setting_change(params) do
    key = params["key"]
    Elevation.describe_setting(key, current_value(key), params["value"])
  end

  # A secret setting's value is in OpenBao and never read back into the page:
  # the audit description has no old value to show for it.
  defp current_value(key), do: current_value(AlexClaw.Config.secret?(key), key)
  defp current_value(true, _key), do: nil
  defp current_value(false, key), do: AlexClaw.Config.get(key)

  defp delete_setting(true, key, socket) do
    {:noreply, put_flash(socket, :error, managed_message(key))}
  end

  # Deleting auth.totp.enabled disables 2FA exactly as setting it to false does.
  defp delete_setting(false, key, socket) do
    Elevation.gated(socket, "#{key}: deleted",
      write: fn -> AlexClaw.Config.remove(key) end,
      after_commit: fn _removed -> AlexClaw.Config.publish(key) end,
      ok: fn socket, _removed ->
        settings = AlexClaw.Config.list()

        socket
        |> put_flash(:info, "Setting '#{key}' deleted")
        |> assign(settings: settings, grouped: group_by_category(settings))
      end
    )
  end

  defp sensitive_key?(key) do
    key_down = String.downcase(key)
    Enum.any?(@sensitive_patterns, &String.contains?(key_down, &1))
  end

  defp mask_value(nil), do: ""
  defp mask_value(""), do: ""

  defp mask_value(value) when byte_size(value) <= 8,
    do: String.duplicate("*", String.length(value))

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

  @category_order ~w(telegram discord llm embedding github google auth shell web_automator skills cluster prompts identity display general)
  @category_labels %{
    "telegram" => "Telegram",
    "discord" => "Discord",
    "llm" => "LLM Providers",
    "embedding" => "Embedding",
    "github" => "GitHub",
    "google" => "Google",
    "auth" => "Authentication",
    "shell" => "Shell",
    "web_automator" => "Web Automator",
    "skills" => "Skills",
    "cluster" => "Cluster",
    "prompts" => "Prompts",
    "identity" => "Identity",
    "display" => "Display",
    "general" => "General"
  }

  defp group_by_category(settings) do
    groups = Enum.group_by(settings, &(&1.category || "general"))

    known = Enum.filter(@category_order, &Map.has_key?(groups, &1))
    extra = Map.keys(groups) |> Enum.reject(&(&1 in @category_order)) |> Enum.sort()

    Enum.map(known ++ extra, fn cat ->
      {cat, Map.get(@category_labels, cat, String.capitalize(cat)), groups[cat]}
    end)
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

  defp node_setting?(key), do: String.ends_with?(key, ".node")

  defp provider_setting?(key), do: key == "embedding.provider"

  defp provider_names do
    AlexClaw.LLM.list_providers()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(& &1.name)
  end

  # Enabling a gateway assigns it to this node — telegram.enabled sets
  # telegram.node — in the same transaction as the setting itself. Answers the
  # further keys it wrote, for publishing after commit.
  defp assign_gateway_node(key, value) when value in ["true", true] do
    assign_node(String.ends_with?(key, ".enabled"), key)
  end

  defp assign_gateway_node(_key, _value), do: {:ok, []}

  defp assign_node(true, key) do
    node_key = String.replace(key, ".enabled", ".node")
    category = key |> String.split(".") |> hd()

    with {:ok, _setting} <-
           AlexClaw.Config.persist(node_key, to_string(node()), category: category) do
      {:ok, [node_key]}
    end
  end

  defp assign_node(false, _key), do: {:ok, []}

  defp cluster_node_names do
    Enum.uniq([to_string(node()) | Enum.map(AlexClaw.Cluster.list_nodes(), & &1.name)])
  end
end
