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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-bold text-white">Skills</h1>
          <p class="text-xs text-gray-500 mt-1">{length(@skills)} registered skills</p>
        </div>
        <span class="text-sm text-gray-500">Running: {@running}</span>
      </div>

      <%!-- Upload section --%>
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-6">
        <h2 class="text-lg font-semibold text-gray-300 mb-2">Upload Skill</h2>
        <p class="text-sm text-gray-500 mb-4">Upload an .ex file to compile and register a dynamic skill.</p>

        <form phx-submit="upload_skill" phx-change="validate_upload" class="space-y-4">
          <div class="flex items-center space-x-4">
            <label class="flex-1">
              <.live_file_input upload={@uploads.skill_file}
                class="block w-full text-sm text-gray-400
                  file:mr-4 file:py-2 file:px-4 file:rounded
                  file:border-0 file:text-sm file:font-semibold
                  file:bg-gray-800 file:text-gray-300
                  hover:file:bg-gray-700 file:cursor-pointer" />
            </label>
          </div>

          <%= for entry <- @uploads.skill_file.entries do %>
            <div class="flex items-center space-x-3 text-sm">
              <span class="text-gray-300">{entry.client_name}</span>
              <span class="text-gray-500">({format_size(entry.client_size)})</span>
            </div>
            <%= for err <- upload_errors(@uploads.skill_file, entry) do %>
              <p class="text-red-400 text-sm">{upload_error_message(err)}</p>
            <% end %>
          <% end %>

          <button type="submit"
            disabled={@uploads.skill_file.entries == [] || @uploading}
            class={[
              "px-4 py-2 text-white text-sm rounded transition",
              if(@uploads.skill_file.entries == [] || @uploading,
                do: "bg-gray-700 cursor-not-allowed",
                else: "bg-claw-700 hover:bg-claw-600")
            ]}>
            {if @uploading, do: "Loading...", else: "Upload & Load"}
          </button>
        </form>
      </div>

      <%!-- Core Skills --%>
      <div>
        <h2 class="text-lg font-semibold text-gray-300 mb-4">Core Skills <span class="text-sm font-normal text-gray-600">({length(Enum.filter(@skills, & &1.type == :core))})</span></h2>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <div :for={skill <- Enum.filter(@skills, & &1.type == :core)} class="bg-gray-900 rounded-lg border border-gray-800 p-6">
            <div class="flex justify-between items-start mb-3">
              <h3 class="text-lg font-semibold text-white">{skill.display_name}</h3>
              <span :if={skill.version} class="px-2 py-0.5 text-xs font-mono text-gray-500 bg-gray-800 rounded-full">
                v{skill.version}
              </span>
            </div>
            <p class="text-sm text-gray-400 mb-4">{skill.doc}</p>
            <div class="text-xs text-gray-600 font-mono">{skill.name}</div>
          </div>
        </div>
      </div>

      <%!-- Dynamic Skills --%>
      <div>
        <h2 class="text-lg font-semibold text-gray-300 mb-4">Dynamic Skills <span class="text-sm font-normal text-gray-600">({length(Enum.filter(@skills, & &1.type == :dynamic))})</span></h2>
        <%= if Enum.any?(@skills, & &1.type == :dynamic) do %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <div :for={skill <- Enum.filter(@skills, & &1.type == :dynamic)} class="bg-gray-900 rounded-lg border border-claw-900/50 p-6">
              <div class="flex justify-between items-start mb-3">
                <h3 class="text-lg font-semibold text-white">{skill.display_name}</h3>
                <span :if={skill.version} class="px-2 py-0.5 text-xs font-mono text-claw-500 bg-claw-900/30 rounded-full">
                  v{skill.version}
                </span>
              </div>
              <p class="text-sm text-gray-400 mb-4">{skill.doc}</p>

              <div :if={is_list(skill.permissions)} class="mb-3">
                <div class="flex flex-wrap gap-1">
                  <span :for={perm <- skill.permissions}
                    class="px-1.5 py-0.5 text-[10px] bg-gray-800 text-gray-500 rounded">
                    {perm}
                  </span>
                </div>
              </div>

              <div class="flex justify-between items-end">
                <div class="text-xs text-gray-600 font-mono">{skill.name}</div>
                <div class="flex gap-2">
                  <button phx-click="reload_skill" phx-value-name={skill.name}
                    class="px-2 py-1 text-xs text-gray-400 hover:text-claw-400 bg-gray-800 hover:bg-gray-700 rounded transition">
                    Reload
                  </button>
                  <button phx-click="unload_skill" phx-value-name={skill.name}
                    data-confirm={"Unload skill '#{skill.name}'?"}
                    class="px-2 py-1 text-xs text-gray-400 hover:text-red-400 bg-gray-800 hover:bg-gray-700 rounded transition">
                    Unload
                  </button>
                </div>
              </div>
            </div>
          </div>
        <% else %>
          <p class="text-sm text-gray-600">No dynamic skills loaded. Upload an .ex file above to get started.</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp upload_error_message(:too_large), do: "File too large (max 1 MB)"
  defp upload_error_message(:not_accepted), do: "Only .ex files accepted"
  defp upload_error_message(err), do: "Error: #{inspect(err)}"
end
