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
    tier = Keyword.get(opts, :tier, resolve_tier())
    provider = Keyword.get(opts, :provider, resolve_provider())
    gateway_opts = Keyword.take(opts, [:gateway, :chat_id])

    case do_research(query, tier: tier, provider: provider) do
      {:ok, response, _branch} -> Gateway.send_message(response, gateway_opts)
      {:error, reason} ->
        Logger.warning("Research failed: #{inspect(reason)}", skill: :research)
        Gateway.send_message("Research failed: #{inspect(reason)}", gateway_opts)
    end
  end

  defp resolve_tier, do: String.to_atom(Config.get("skill.research.tier") || "medium")
  defp resolve_provider do
    case Config.get("skill.research.provider") do
      p when p in [nil, "", "auto"] -> nil
      p -> p
    end
  end

  defp do_research(query, llm_opts \\ []) do
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

    tier = Keyword.get(llm_opts, :tier, resolve_tier())
    provider = Keyword.get(llm_opts, :provider, resolve_provider())
    complete_opts = [tier: tier, system: system] ++ if(provider, do: [provider: provider], else: [])

    case LLM.complete(prompt, complete_opts) do
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
