defmodule AlexClaw.Skills.Research do
  @moduledoc """
  Deep research skill. Searches memory for existing context,
  synthesizes with LLM, stores the summary, and replies.
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec external() :: boolean()
  def external, do: true
  @impl true
  @spec description() :: String.t()
  def description, do: "Deep research with memory context and LLM synthesis"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_results, :on_error]
  require Logger

  alias AlexClaw.{Config, Gateway, Identity, LLM, Memory}

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:llm_tier, :llm_model, :prompt_template, :config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"query": "research topic"}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"query" => ""}

  @impl true
  @spec config_help() :: String.t()
  def config_help, do: "query: the research topic. Leave empty to use {input} from the previous step."

  @impl true
  @spec prompt_help() :: String.t()
  def prompt_help, do: "Research query template. Use {input} to include data from the previous step."

  @impl true
  @spec run(map()) :: {:ok, String.t(), atom()} | {:error, any()}
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

  defp resolve_tier, do: String.to_existing_atom(Config.get("skill.research.tier") || "medium")
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
          Enum.map_join(entries, "\n---\n", & &1.content)
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
