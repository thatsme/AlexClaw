defmodule AlexClawWeb.AdminLive.Skills do
  @moduledoc "LiveView page listing all registered skills with upload and unload for dynamic skills."

  use Phoenix.LiveView
  require Logger

  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context
  alias AlexClaw.Workflows.SkillRegistry
  alias AlexClawWeb.Live.{ActionCode, Elevation}

  @max_upload_size 1_000_000

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, "skills:registry")
    end

    {:ok,
     socket
     |> Elevation.assign_elevation(session)
     |> ActionCode.assign_action_code()
     |> assign(
       page_title: "Skills",
       skills: build_skill_list(),
       running: get_running_skills(),
       uploading: false,
       upload_result: nil,
       pending_2fa: nil
     )
     |> allow_upload(:skill_file,
       # `.ex` has no registered MIME type, so allow_upload/3 refuses it as an
       # accept filter. The filename is enforced server-side in store_upload/2.
       accept: :any,
       max_entries: 1,
       max_file_size: @max_upload_size
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("upload_skill", _params, socket) do
    socket = assign(socket, uploading: true, upload_result: nil)

    result =
      consume_uploaded_entries(socket, :skill_file, fn %{path: tmp_path}, entry ->
        {:ok, store_upload(socket, tmp_path, entry.client_name)}
      end)

    case result do
      [filename] when is_binary(filename) ->
        upload_skill(socket, filename)

      [{:error, :invalid_filename}] ->
        {:noreply,
         socket
         |> put_flash(:error, "Rejected: skill files must be a plain .ex filename")
         |> assign(uploading: false)}

      [{:error, :second_factor_required}] ->
        {:noreply,
         socket
         |> Elevation.refresh()
         |> put_flash(:error, "Unlock editing first")
         |> assign(uploading: false)}

      [] ->
        {:noreply, socket |> put_flash(:error, "No file selected") |> assign(uploading: false)}
    end
  end

  @impl true
  def handle_event("unload_skill", %{"name" => name}, socket) do
    socket
    |> assign(pending_2fa: name)
    |> ActionCode.request(%{type: :skill_unload, name: name}, "Unload skill: #{name}")
  end

  @impl true
  def handle_event("reload_skill", %{"name" => name}, socket) do
    socket
    |> assign(pending_2fa: name)
    |> ActionCode.request(%{type: :skill_reload, name: name}, "Reload skill: #{name}")
  end

  def handle_event("submit_action_code", %{"code" => code}, socket) do
    ActionCode.submit(socket, code)
  end

  def handle_event("cancel_action_code", _params, socket) do
    ActionCode.cancel(socket)
  end

  defp upload_skill(socket, filename) do
    socket
    |> assign(uploading: false, pending_2fa: filename)
    |> ActionCode.request(%{type: :skill_load, file_path: filename}, "Load skill: #{filename}")
  end

  # Staged under skills_dir/pending, never the live directory: until the 2FA code
  # is verified the upload cannot replace a skill that is already loaded.
  defp store_upload(socket, tmp_path, client_name) do
    case ControlPlane.perform(
           :stage_skill,
           %{path: tmp_path, name: client_name},
           Context.admin_ui(socket.assigns.elevation_sid)
         ) do
      {:ok, file_name} ->
        file_name

      {:error, reason} ->
        Logger.warning("Rejected skill upload #{inspect(client_name)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def handle_info({:skill_registered, _name}, socket) do
    {:noreply, assign(socket, skills: build_skill_list(), pending_2fa: nil)}
  end

  def handle_info({:skill_unregistered, _name}, socket) do
    {:noreply, assign(socket, skills: build_skill_list(), pending_2fa: nil)}
  end

  defp build_skill_list do
    Enum.map(SkillRegistry.list_all_with_type(), fn {name, module, type, permissions, routes,
                                                     _ext} ->
      %{
        name: name,
        module: module,
        type: type,
        permissions: permissions,
        routes: routes,
        display_name:
          name
          |> String.replace("_", " ")
          |> String.split(" ")
          |> Enum.map_join(" ", &String.capitalize/1),
        doc: get_description(module),
        version: get_version(module)
      }
    end)
  end

  defp get_running_skills do
    DynamicSupervisor.count_children(AlexClaw.SkillSupervisor).active
  end

  defp get_description(module) do
    if function_exported?(module, :description, 0),
      do: module.description(),
      else: "No description available"
  end

  defp get_version(module) do
    if function_exported?(module, :version, 0), do: module.version(), else: nil
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp upload_error_message(:too_large), do: "File too large (max 1 MB)"
  defp upload_error_message(:not_accepted), do: "Only .ex files accepted"
  defp upload_error_message(err), do: "Error: #{inspect(err)}"
end
