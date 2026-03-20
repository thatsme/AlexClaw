defmodule AlexClaw.Skills.Research do
  @moduledoc """
  Deep research skill. Searches memory for existing context,
  synthesizes with LLM, stores the summary, and replies.
  """
  @behaviour AlexClaw.Skill
  @impl true
  def description, do: "Deep research with memory context and LLM synthesis"

  @impl true
  def routes, do: [:on_results, :on_error]
  require Logger

  alias AlexClaw.{Config, Gateway, Identity, LLM, Memory}

  @impl true
  def run(args) do
    query = args[:input] || args[:config]["query"] || ""

    if query == "" do
      {:error, :no_query}
    else
      do_research(to_string(query))
    end
  end

  @spec handle(String.t(), keyword()) :: :ok
  def handle(query, opts \\ []) do
    case do_research(query) do
      {:ok, response, _branch} -> Gateway.send_message(response, opts)
      {:error, reason} ->
        Logger.warning("Research failed: #{inspect(reason)}", skill: :research)
        Gateway.send_message("Research failed: #{inspect(reason)}", opts)
    end
  end

  defp do_research(query) do
    Logger.info("Research: #{query}", skill: :research)
    system = Identity.system_prompt(%{skill: :research})
    research_instruction = Config.get("prompts.research.system")

    existing =
      case Memory.search(query, limit: 5) do
        [] ->
          "No prior context found."

        entries ->
          entries
          |> Enum.map_join("\n---\n", & &1.content)
      end

    prompt = """
    Research query: #{query}

    Existing knowledge:
    #{existing}

    #{research_instruction}
    """

    case LLM.complete(prompt, tier: :medium, system: system) do
      {:ok, response} ->
        Memory.store(:summary, response,
          source: "research:#{query}",
          metadata: %{query: query}
        )

        {:ok, response, :on_results}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
