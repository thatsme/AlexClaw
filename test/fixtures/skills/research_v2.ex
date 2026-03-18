defmodule AlexClaw.Skills.Dynamic.ResearchV2 do
  @moduledoc """
  Dynamic deep research skill. Searches memory for existing context,
  synthesizes with LLM, stores the summary.
  """
  @behaviour AlexClaw.Skill

  alias AlexClaw.Skills.SkillAPI

  @impl true
  def version, do: "1.0.0"

  @impl true
  def permissions, do: [:llm, :memory_read, :memory_write, :config_read]

  @impl true
  def description, do: "Deep research with memory context and LLM synthesis (dynamic)"

  @impl true
  def run(args) do
    query = args[:input] || (args[:config] || %{})["query"] || ""

    if query == "" do
      {:error, :no_query}
    else
      do_research(to_string(query))
    end
  end

  defp do_research(query) do
    {:ok, system} = SkillAPI.system_prompt(__MODULE__, %{skill: :research})
    {:ok, research_instruction} = SkillAPI.config_get(__MODULE__, "prompts.research.system")

    existing =
      case SkillAPI.memory_search(__MODULE__, query, limit: 5) do
        {:ok, []} ->
          "No prior context found."

        {:ok, entries} ->
          Enum.map_join(entries, "\n---\n", & &1.content)

        _ ->
          "No prior context found."
      end

    prompt = """
    Research query: #{query}

    Existing knowledge:
    #{existing}

    #{research_instruction}
    """

    case SkillAPI.llm_complete(__MODULE__, prompt, tier: :medium, system: system) do
      {:ok, response} ->
        SkillAPI.memory_store(__MODULE__, :summary, response,
          source: "research:#{query}",
          metadata: %{query: query}
        )

        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
