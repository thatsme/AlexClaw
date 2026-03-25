defmodule AlexClawWeb.AdminLive.Policies do
  @moduledoc "LiveView page for managing authorization policies and viewing audit log."

  use Phoenix.LiveView

  alias AlexClaw.Auth.{Policy, AuditLog, PolicyEngine}
  alias AlexClaw.Repo

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Policies",
       tab: :policies,
       policies: list_policies(),
       audit_entries: AuditLog.recent(limit: 50),
       form: default_form(),
       editing: nil
     )}
  end

  @scaffolds %{
    "rate_limit" => %{"permission" => "llm", "max_calls" => 10, "window_seconds" => 60},
    "time_window" => %{"permission" => "llm", "deny_start_hour" => 0, "deny_end_hour" => 6},
    "chain_restriction" => %{"caller_pattern" => "Dynamic"},
    "permission_override" => %{"permission" => "shell", "action" => "deny", "expires_at" => nil}
  }

  @impl true
  def handle_event("rule_type_changed", %{"policy" => params}, socket) do
    rule_type = params["rule_type"]
    previous_type = socket.assigns.form.params["rule_type"]

    form_data = Map.merge(socket.assigns.form.params, params)

    form_data =
      if rule_type != previous_type do
        scaffold_json =
          case Map.get(@scaffolds, rule_type) do
            nil -> "{}"
            scaffold -> Jason.encode!(scaffold, pretty: true)
          end

        Map.put(form_data, "config_json", scaffold_json)
      else
        form_data
      end

    {:noreply, assign(socket, form: to_form(form_data, as: :policy))}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab = String.to_existing_atom(tab)

    socket =
      case tab do
        :audit -> assign(socket, tab: tab, audit_entries: AuditLog.recent(limit: 50))
        _ -> assign(socket, tab: tab)
      end

    {:noreply, socket}
  end

  def handle_event("create_policy", %{"policy" => params}, socket) do
    config = parse_config(params["config_json"] || "{}")

    attrs = %{
      name: params["name"],
      description: params["description"],
      rule_type: params["rule_type"],
      config: config,
      priority: parse_int(params["priority"], 0),
      enabled: params["enabled"] == "true"
    }

    case %Policy{} |> Policy.changeset(attrs) |> Repo.insert() do
      {:ok, _policy} ->
        PolicyEngine.reload_policies()

        {:noreply,
         socket
         |> put_flash(:info, "Policy created")
         |> assign(policies: list_policies(), form: default_form())}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Invalid policy")}
    end
  end

  def handle_event("edit_policy", %{"id" => id}, socket) do
    policy = Repo.get!(Policy, id)

    form_data = %{
      "id" => to_string(policy.id),
      "name" => policy.name,
      "description" => policy.description || "",
      "rule_type" => policy.rule_type,
      "config_json" => Jason.encode!(policy.config),
      "priority" => to_string(policy.priority),
      "enabled" => to_string(policy.enabled)
    }

    {:noreply, assign(socket, editing: policy.id, form: to_form(form_data, as: :policy))}
  end

  def handle_event("cancel_edit", _, socket) do
    {:noreply, assign(socket, editing: nil, form: default_form())}
  end

  def handle_event("update_policy", %{"policy" => params}, socket) do
    policy = Repo.get!(Policy, params["id"])
    config = parse_config(params["config_json"] || "{}")

    attrs = %{
      name: params["name"],
      description: params["description"],
      rule_type: params["rule_type"],
      config: config,
      priority: parse_int(params["priority"], 0),
      enabled: params["enabled"] == "true"
    }

    case policy |> Policy.changeset(attrs) |> Repo.update() do
      {:ok, _} ->
        PolicyEngine.reload_policies()

        {:noreply,
         socket
         |> put_flash(:info, "Policy updated")
         |> assign(editing: nil, policies: list_policies(), form: default_form())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid policy")}
    end
  end

  def handle_event("toggle_policy", %{"id" => id}, socket) do
    policy = Repo.get!(Policy, id)
    {:ok, _} = policy |> Policy.changeset(%{enabled: !policy.enabled}) |> Repo.update()
    PolicyEngine.reload_policies()
    {:noreply, assign(socket, policies: list_policies())}
  end

  def handle_event("delete_policy", %{"id" => id}, socket) do
    Repo.get!(Policy, id) |> Repo.delete!()
    PolicyEngine.reload_policies()

    {:noreply,
     socket
     |> put_flash(:info, "Policy deleted")
     |> assign(policies: list_policies())}
  end

  def handle_event("prune_audit", _, socket) do
    {count, _} = AuditLog.prune()

    {:noreply,
     socket
     |> put_flash(:info, "Pruned #{count} old audit entries")
     |> assign(audit_entries: AuditLog.recent(limit: 50))}
  end

  def handle_event("refresh_audit", _, socket) do
    {:noreply, assign(socket, audit_entries: AuditLog.recent(limit: 50))}
  end

  # --- Helpers ---

  defp tip(assigns) do
    ~H"""
    <span class="relative inline-block ml-1 group">
      <span class="inline-flex items-center justify-center w-4 h-4 rounded-full bg-gray-700 text-gray-400 text-[10px] cursor-help group-hover:bg-yellow-400 group-hover:text-black transition">?</span>
      <span class="absolute bottom-full left-0 mb-2 px-3 py-2 bg-yellow-400 text-black text-xs rounded shadow-lg w-64 hidden group-hover:block z-50">
        {@text}
      </span>
    </span>
    """
  end

  defp rule_type_help(rule_type) do
    case rule_type do
      "rate_limit" -> "Limits how many times a permission can be used within a time window. Applies per-skill."
      "time_window" -> "Blocks a permission during specific UTC hours. Use for quiet hours or maintenance windows."
      "chain_restriction" -> "Prevents skills matching a pattern from invoking other skills. Stops recursive chains."
      "permission_override" -> "Temporarily grants or denies a specific permission. Optional expiry date."
      _ -> "Select a rule type."
    end
  end

  defp default_form do
    to_form(
      %{
        "rule_type" => "rate_limit",
        "config_json" => Jason.encode!(@scaffolds["rate_limit"], pretty: true)
      },
      as: :policy
    )
  end

  defp list_policies do
    Repo.all(from(p in Policy, order_by: [desc: p.priority, asc: p.name]))
  rescue
    _ -> []
  end

  defp parse_config(json_str) do
    case Jason.decode(json_str) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end
end
