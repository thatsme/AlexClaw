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

  alias AlexClaw.{Config, Identity, LLM, Memory}
  alias AlexClaw.RAG.Fallback

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
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema, do: %{"query" => %{type: :string, required: false}}

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do: "query: the research topic. Leave empty to use {input} from the previous step."

  @impl true
  @spec prompt_help() :: String.t()
  def prompt_help,
    do: "Research query template. Use {input} to include data from the previous step."

  @impl true
  @spec run(map()) :: {:ok, String.t(), atom()} | {:error, any()}
  def run(args) do
    run_query(resolved_query(args), args)
  end

  defp run_query("", _args), do: {:error, :no_query}
  defp run_query(query, args), do: do_research(query, step_llm_opts(args))

  # A step that sets a prompt template researches the rendered template, not the
  # raw input. {input} is the placeholder prompt_help/0 documents.
  defp resolved_query(%{prompt_template: template} = args)
       when is_binary(template) and template != "",
       do: String.replace(template, "{input}", to_string(args[:input] || ""))

  defp resolved_query(args), do: to_string(args[:input] || args[:config]["query"] || "")

  # The step's own tier and provider win over the skill-wide defaults; unset or
  # "auto" leaves resolve_tier/0 and resolve_provider/0 in charge.
  defp step_llm_opts(args), do: tier_opt(args[:llm_tier]) ++ provider_opt(args[:llm_provider])

  defp tier_opt(tier) when tier in ~w(local light medium heavy),
    do: [tier: String.to_existing_atom(tier)]

  defp tier_opt(_tier), do: []

  defp provider_opt(provider) when provider in [nil, "", "auto"], do: []
  defp provider_opt(provider), do: [provider: provider]

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

    prompt =
      case Fallback.search_with_fallback(query) do
        {:ok, context, _strategy} ->
          """
          Research query: #{query}

          Existing knowledge:
          #{context}

          #{research_instruction}
          """

        {:no_context, _strategy} ->
          """
          Research query: #{query}

          #{research_instruction}
          """
      end

    tier = Keyword.get(llm_opts, :tier, resolve_tier())
    provider = Keyword.get(llm_opts, :provider, resolve_provider())

    complete_opts =
      [tier: tier, system: system] ++ if(provider, do: [provider: provider], else: [])

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
