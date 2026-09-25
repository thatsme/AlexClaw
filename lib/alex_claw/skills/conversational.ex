defmodule AlexClaw.Skills.Conversational do
  @moduledoc """
  Free-text conversation skill. Passes unrecognized messages to the LLM
  with identity context and recent memory.
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec description() :: String.t()
  def description, do: "Free-text conversation with identity and memory context"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_success, :on_error]

  require Logger

  alias AlexClaw.{Config, Identity, LLM, Memory}

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:llm_tier, :llm_model, :prompt_template, :config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"message": "text to send"}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"message" => ""}

  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema, do: %{"message" => %{type: :string, required: false}}

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do: "message: text to send to the LLM. Leave empty to use {input} from the previous step."

  @impl true
  @spec prompt_help() :: String.t()
  def prompt_help, do: "Message template. Use {input} to include data from the previous step."

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    do_converse(resolved_message(args), step_llm_opts(args))
  end

  # A step that sets a prompt template sends the rendered template, not the raw
  # input. {input} is the placeholder prompt_help/0 documents.
  defp resolved_message(%{prompt_template: template} = args)
       when is_binary(template) and template != "",
       do: String.replace(template, "{input}", to_string(args[:input] || ""))

  defp resolved_message(args), do: to_string(args[:input] || args[:config]["message"] || "")

  # The step's own tier and provider win over the skill-wide defaults; unset or
  # "auto" leaves skill.conversational.* in charge.
  defp step_llm_opts(args), do: tier_opt(args[:llm_tier]) ++ provider_opt(args[:llm_provider])

  defp tier_opt(tier) when tier in ~w(local light medium heavy),
    do: [tier: String.to_existing_atom(tier)]

  defp tier_opt(_tier), do: []

  defp provider_opt(provider) when provider in [nil, "", "auto"], do: []
  defp provider_opt(provider), do: [provider: provider]

  defp do_converse(text, opts) do
    system = Identity.system_prompt(%{skill: :conversational})

    context =
      case Memory.recent(kind: :conversation, limit: 5) do
        [] ->
          ""

        entries ->
          history =
            entries
            |> Enum.reverse()
            |> Enum.map_join("\n", & &1.content)

          "\n\nRecent conversation:\n#{history}"
      end

    prompt = "#{context}\n\nUser: #{text}"

    tier = Keyword.get(opts, :tier, config_tier())
    provider = Keyword.get(opts, :provider, config_provider())

    llm_opts = [tier: tier, system: system] ++ if(provider, do: [provider: provider], else: [])

    case LLM.complete(prompt, llm_opts) do
      {:ok, response} -> {:ok, response, :on_success}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config_tier,
    do: String.to_existing_atom(Config.get("skill.conversational.tier") || "light")

  defp config_provider do
    case Config.get("skill.conversational.provider") do
      p when p in [nil, "", "auto"] -> nil
      p -> p
    end
  end
end
