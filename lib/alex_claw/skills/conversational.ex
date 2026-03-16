defmodule AlexClaw.Skills.Conversational do
  @moduledoc """
  Free-text conversation skill. Passes unrecognized messages to the LLM
  with identity context and recent memory.
  """
  @behaviour AlexClaw.Skill
  @impl true
  def description, do: "Free-text conversation with identity and memory context"
  require Logger

  alias AlexClaw.{Gateway, Identity, LLM, Memory}

  @impl true
  def run(args) do
    text = args[:input] || args[:config]["message"] || ""
    do_converse(to_string(text))
  end

  @spec handle(AlexClaw.Message.t()) :: :ok
  def handle(message) do
    case do_converse(message.text) do
      {:ok, response} ->
        Memory.store(:conversation, "User: #{message.text}", source: "telegram")
        Memory.store(:conversation, "AlexClaw: #{response}", source: "telegram")
        Gateway.send_message(response)

      {:error, reason} ->
        Logger.warning("Conversational skill failed: #{inspect(reason)}")
        Gateway.send_message("Something went wrong. Try again.")
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

    case LLM.complete(prompt, tier: :light, system: system) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end
end
