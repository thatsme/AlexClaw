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
       form: to_form(%{}, as: :policy),
       editing: nil
     )}
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
         |> assign(policies: list_policies(), form: to_form(%{}, as: :policy))}

      {:error, _changeset} ->
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
