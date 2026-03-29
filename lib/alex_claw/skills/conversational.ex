defmodule AlexClaw.Skills.Conversational do
  @moduledoc """
  Free-text conversation skill. Passes unrecognized messages to the LLM
  with identity context and recent memory.
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec description() :: String.t()
  def description, do: "Free-text conversation with identity and memory context"
  require Logger

  alias AlexClaw.{Config, Gateway, Identity, LLM, Memory}

  @impl true
  def step_fields, do: [:llm_tier, :llm_model, :prompt_template]

  @impl true
  def config_hint, do: ~s|{"message": "text to send"}|

  @impl true
  def config_scaffold, do: %{"message" => ""}

  @impl true
  def config_help, do: "message: text to send to the LLM. Leave empty to use {input} from the previous step."

  @impl true
  def prompt_help, do: "Message template. Use {input} to include data from the previous step."

  @impl true
  @spec run(map()) :: {:ok, any(), atom()} | {:error, any()}
  def run(args) do
    text = args[:input] || args[:config]["message"] || ""
    do_converse(to_string(text))
  end

  @spec handle(AlexClaw.Message.t()) :: :ok
  def handle(message) do
    opts = [gateway: message.gateway]
    source = to_string(message.gateway || "chat")

    case do_converse(message.text) do
      {:ok, response, _branch} ->
        Memory.store(:conversation, "User: #{message.text}", source: source)
        Memory.store(:conversation, "AlexClaw: #{response}", source: source)
        Gateway.send_message(response, opts)

      {:error, reason} ->
        Logger.warning("Conversational skill failed: #{inspect(reason)}")
        Gateway.send_message("Something went wrong. Try again.", opts)
    end
  end

  defp do_converse(text) do
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

    tier = String.to_existing_atom(Config.get("skill.conversational.tier") || "light")
    provider = case Config.get("skill.conversational.provider") do
      p when p in [nil, "", "auto"] -> nil
      p -> p
    end
    llm_opts = [tier: tier, system: system] ++ if(provider, do: [provider: provider], else: [])

    case LLM.complete(prompt, llm_opts) do
      {:ok, response} -> {:ok, response, :on_success}
      {:error, reason} -> {:error, reason}
    end
  end
end
