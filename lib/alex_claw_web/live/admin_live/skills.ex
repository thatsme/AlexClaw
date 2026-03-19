defmodule AlexClawWeb.AdminLive.Skills do
  @moduledoc "LiveView page listing all registered skills with upload and unload for dynamic skills."

  use Phoenix.LiveView

  alias AlexClaw.Workflows.SkillRegistry

  @max_upload_size 1_000_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, "skills:registry")
    end

    {:ok,
     socket
     |> assign(
       page_title: "Skills",
       skills: build_skill_list(),
       running: get_running_skills(),
       uploading: false,
       upload_result: nil
     )
     |> allow_upload(:skill_file,
       accept: :any,
       max_entries: 1,
       max_file_size: @max_upload_size
     )}
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("upload_skill", _params, socket) do
    socket = assign(socket, uploading: true, upload_result: nil)

    result =
      consume_uploaded_entries(socket, :skill_file, fn %{path: tmp_path}, entry ->
        skills_dir = Application.get_env(:alex_claw, :skills_dir, "/app/skills")
        dest = Path.join(skills_dir, entry.client_name)
        File.cp!(tmp_path, dest)
        {:ok, entry.client_name}
      end)

    case result do
      [filename] when is_binary(filename) ->
        case SkillRegistry.load_skill(filename) do
          {:ok, %{name: name, permissions: perms}} ->
            perm_list = Enum.map_join(perms, ", ", &to_string/1)

            {:noreply,
             socket
             |> put_flash(:info, "Skill '#{name}' loaded. Permissions: #{perm_list}")
             |> assign(uploading: false, skills: build_skill_list())}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Load failed: #{format_error(reason)}")
             |> assign(uploading: false)}
        end

      [] ->
        {:noreply,
         socket
         |> put_flash(:error, "No file selected")
         |> assign(uploading: false)}
    end
  end

  @impl true
  def handle_event("unload_skill", %{"name" => name}, socket) do
    case SkillRegistry.unload_skill(name) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Skill '#{name}' unloaded")
         |> assign(skills: build_skill_list())}

      {:error, :cannot_unload_core} ->
        {:noreply, put_flash(socket, :error, "Cannot unload core skills")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill not found")}
    end
  end

  @impl true
  def handle_event("reload_skill", %{"name" => name}, socket) do
    case SkillRegistry.reload_skill(name) do
      {:ok, %{name: n, permissions: perms}} ->
        perm_list = Enum.map_join(perms, ", ", &to_string/1)

        {:noreply,
         socket
         |> put_flash(:info, "Skill '#{n}' reloaded. Permissions: #{perm_list}")
         |> assign(skills: build_skill_list())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reload failed: #{format_error(reason)}")}
    end
  end

  @impl true
  def handle_info({:skill_registered, _name}, socket) do
    {:noreply, assign(socket, skills: build_skill_list())}
  end

  def handle_info({:skill_unregistered, _name}, socket) do
    {:noreply, assign(socket, skills: build_skill_list())}
  end

  defp build_skill_list do
    SkillRegistry.list_all_with_type()
    |> Enum.map(fn {name, module, type, permissions, routes} ->
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
    if function_exported?(module, :description, 0), do: module.description(), else: "No description available"
  end

  defp get_version(module) do
    if function_exported?(module, :version, 0), do: module.version(), else: nil
  end

  defp format_error({:invalid_namespace, ns}), do: "Module must be under AlexClaw.Skills.Dynamic.*, got #{ns}"
  defp format_error(:missing_run_callback), do: "Module must export run/1"
  defp format_error({:unknown_permissions, invalid}), do: "Unknown permissions: #{inspect(invalid)}"
  defp format_error(:name_conflicts_with_core), do: "Name conflicts with a core skill"
  defp format_error({:compilation_error, msg}), do: "Compilation error: #{String.slice(msg, 0, 300)}"
  defp format_error(:path_traversal), do: "Invalid file path"
  defp format_error(:file_not_found), do: "File not found"
  defp format_error(reason), do: inspect(reason)

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp upload_error_message(:too_large), do: "File too large (max 1 MB)"
  defp upload_error_message(:not_accepted), do: "Only .ex files accepted"
  defp upload_error_message(err), do: "Error: #{inspect(err)}"
end
