defmodule AlexClaw.FailureText do
  @moduledoc """
  A failure reason as an operator reads it on a gateway: the message an error
  carries (an LLM provider's reply, for one), prefixed by what failed, rather
  than the raw term — which could be a whole API response, too long for a chat
  message and unreadable in one.
  """

  @doc "A failure reason in words, at most 300 characters."
  @spec describe(term()) :: String.t()
  def describe(reason) do
    reason
    |> error_message()
    |> Kernel.||(inspect(reason))
    |> String.slice(0, 300)
  end

  defp error_message({source, status, body}) when is_atom(source) and is_integer(status),
    do: with_status(error_message(body), status)

  defp error_message({:prompt_too_large, [_ | _] = providers}) do
    "prompt too large for " <>
      Enum.map_join(providers, ", ", fn p ->
        "#{p.provider} (window #{p.window || "unknown"}, needs ~#{p.prompt_tokens} tokens)"
      end)
  end

  defp error_message(:local_model_busy),
    do: "a local model call is already running — only one runs at a time"

  defp error_message({tag, inner}) when is_atom(tag), do: prefixed(tag, error_message(inner))
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(%{"error" => error}), do: error_message(error)
  defp error_message(message) when is_binary(message), do: message
  defp error_message(atom) when is_atom(atom) and not is_nil(atom), do: humanized(atom)
  defp error_message(_other), do: nil

  defp with_status(nil, status), do: "HTTP #{status}"
  defp with_status(message, status), do: "HTTP #{status}: #{message}"

  defp prefixed(_tag, nil), do: nil
  defp prefixed(tag, message), do: "#{humanized(tag)}: #{message}"

  defp humanized(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")
end
