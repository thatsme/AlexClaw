defmodule AlexClawWeb.AdminLive.Feeds do
  @moduledoc "LiveView page for managing RSS feed resources."

  use Phoenix.LiveView

  alias AlexClaw.Resources

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "RSS Feeds",
       feeds: load_feeds(),
       show_form: false
     )}
  end

  @impl true
  def handle_event("toggle_form", _, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form)}
  end

  @impl true
  def handle_event("add_feed", %{"name" => name, "url" => url}, socket) do
    case Resources.create_resource(%{name: name, type: "rss_feed", url: url, enabled: true}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Feed '#{name}' added")
         |> assign(feeds: load_feeds(), show_form: false)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("delete_feed", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, rid} ->
        case Resources.get_resource(rid) do
          {:ok, resource} ->
            {:ok, _} = Resources.delete_resource(resource)

            {:noreply,
             socket
             |> put_flash(:info, "Feed removed")
             |> assign(feeds: load_feeds())}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Feed not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_feed", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, rid} ->
        case Resources.get_resource(rid) do
          {:ok, resource} ->
            {:ok, _} = Resources.update_resource(resource, %{enabled: !resource.enabled})
            {:noreply, assign(socket, feeds: load_feeds())}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Feed not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp load_feeds do
    Resources.list_resources(%{type: "rss_feed"})
  end

end
