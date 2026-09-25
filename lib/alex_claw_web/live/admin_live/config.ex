defmodule AlexClawWeb.AdminLive.Config do
  @moduledoc "LiveView page for viewing and editing key-value configuration settings."

  use Phoenix.LiveView
  alias AlexClaw.Config.SecretSettings
  alias AlexClawWeb.AdminLive.Config.McpKeyPanel
  alias AlexClawWeb.Live.Elevation

  @gateway_owners ~w(telegram.chat_id discord.channel_id)

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
       secret_states: secret_states(),
       mcp_key_configured: McpKeyPanel.configured?(),
       new_mcp_key: nil,
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

    {:noreply,
     assign(socket,
       settings: settings,
       grouped: group_by_category(settings),
       secret_states: secret_states(),
       mcp_key_configured: McpKeyPanel.configured?()
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_form", _, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, editing: nil)}
  end

  def handle_event("generate_mcp_key", _params, socket), do: McpKeyPanel.generate(socket)
  def handle_event("revoke_mcp_key", _params, socket), do: McpKeyPanel.revoke(socket)

  def handle_event("dismiss_mcp_key", _params, socket),
    do: {:noreply, assign(socket, new_mcp_key: nil)}

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
    |> clearing_secret?()
    |> clear_or_save(params, socket)
  end

  # Empty keeps a secret setting's value, so its Clear button is its own
  # action: Config.clear/1 deletes the value from OpenBao.
  defp clearing_secret?(params),
    do: params["_clear"] == "true" and AlexClaw.Config.secret?(params["key"] || "")

  defp clear_or_save(true, %{"key" => key}, socket) do
    Elevation.perform(socket, :clear_secret, %{key: key, detail: "#{key}: cleared"},
      ok: fn socket, _key ->
        settings = AlexClaw.Config.list()

        socket
        |> put_flash(:info, "Setting '#{key}' cleared")
        |> assign(
          settings: settings,
          grouped: group_by_category(settings),
          secret_states: secret_states(),
          show_form: false,
          editing: nil
        )
      end
    )
  end

  defp clear_or_save(false, params, socket) do
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

    Elevation.perform(
      socket,
      setting_action(key),
      %{
        key: key,
        value: value || "",
        opts: [
          type: params["type"],
          description: params["description"],
          category: params["category"] |> to_string() |> String.trim() |> String.downcase(),
          sensitive: sensitive_key?(key)
        ],
        detail: setting_change(params)
      },
      ok: fn socket, _keys ->
        settings = AlexClaw.Config.list()

        socket
        |> put_flash(:info, "Setting '#{key}' saved")
        |> assign(
          settings: settings,
          grouped: group_by_category(settings),
          secret_states: secret_states(),
          show_form: false,
          editing: nil
        )
      end
    )
  end

  # Which chat a gateway answers is its own action: the owner chat receives
  # every code prompt.
  defp setting_action(key) when key in @gateway_owners, do: :set_gateway_owner

  defp setting_action(key),
    do: if(AlexClaw.Config.secret?(key), do: :set_secret, else: :set_setting)

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
    Elevation.perform(
      socket,
      setting_action(key),
      %{key: key, delete: true, detail: "#{key}: deleted"},
      ok: fn socket, _removed ->
        settings = AlexClaw.Config.list()

        socket
        |> put_flash(:info, "Setting '#{key}' deleted")
        |> assign(
          settings: settings,
          grouped: group_by_category(settings),
          secret_states: secret_states()
        )
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

  # A secret setting's value is in OpenBao: the page says whether and when it
  # was set, never any part of the value. Kept as an assign, recomputed with the
  # settings, so LiveView re-renders it when it changes.
  defp secret_states do
    Map.new(SecretSettings.keys(), &{&1, secret_state(&1)})
  end

  defp secret_state(key) do
    case AlexClaw.Config.secret_set_at(key) do
      nil -> "not set"
      set_at -> "set on " <> Calendar.strftime(set_at, "%Y-%m-%d %H:%M UTC")
    end
  end

  defp value_hint(setting, secret_states),
    do: Map.get_lazy(secret_states, setting.key, fn -> mask_value(setting.value) end)

  defp display_value(setting, secret_states),
    do: Map.get_lazy(secret_states, setting.key, fn -> shown_value(setting) end)

  defp shown_value(setting) do
    if setting.sensitive || sensitive_key?(setting.key) do
      mask_value(setting.value)
    else
      String.slice(setting.value, 0, 80)
    end
  end

  @category_order ~w(telegram discord llm embedding github google mcp auth shell web_automator skills cluster prompts identity display general)
  @category_labels %{
    "telegram" => "Telegram",
    "discord" => "Discord",
    "llm" => "LLM Providers",
    "embedding" => "Embedding",
    "github" => "GitHub",
    "google" => "Google",
    "mcp" => "MCP",
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

  # The MCP key has no value to show or edit, only its panel, so its row is not
  # listed; the "mcp" group is always there to hold the panel.
  defp group_by_category(settings) do
    groups =
      settings
      |> Enum.reject(&SecretSettings.recognised_only?(&1.key))
      |> Enum.group_by(&(&1.category || "general"))
      |> Map.put_new("mcp", [])

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

  defp cluster_node_names do
    Enum.uniq([to_string(node()) | Enum.map(AlexClaw.Cluster.list_nodes(), & &1.name)])
  end
end
