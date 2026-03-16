defmodule AlexClawWeb.AdminLive.Skills do
  @moduledoc "LiveView page listing all registered skills and their descriptions."

  use Phoenix.LiveView

  alias AlexClaw.Workflows.SkillRegistry

  @impl true
  def mount(_params, _session, socket) do
    skills =
      SkillRegistry.list_all()
      |> Enum.map(fn {name, module} ->
        %{
          name: name,
          module: module,
          display_name: name |> String.replace("_", " ") |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1),
          doc: get_description(module)
        }
      end)

    {:ok,
     assign(socket,
       page_title: "Skills",
       skills: skills,
       running: get_running_skills()
     )}
  end

  defp get_running_skills do
    DynamicSupervisor.count_children(AlexClaw.SkillSupervisor).active
  end

  defp get_description(module) do
    if function_exported?(module, :description, 0) do
      module.description()
    else
      "No description available"
    end
  end

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

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <div :for={skill <- @skills} class="bg-gray-900 rounded-lg border border-gray-800 p-6">
          <div class="flex justify-between items-start mb-3">
            <h3 class="text-lg font-semibold text-white">{skill.display_name}</h3>
          </div>
          <p class="text-sm text-gray-400 mb-4">{skill.doc}</p>
          <div class="space-y-1">
            <div class="text-xs text-gray-600 font-mono">{skill.name}</div>
            <div class="text-xs text-gray-700 font-mono">{inspect(skill.module)}</div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
