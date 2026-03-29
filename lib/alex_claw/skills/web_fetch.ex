defmodule AlexClaw.Skills.WebFetch do
  @moduledoc """
  Pure URL fetch skill. Fetches a URL, extracts readable text content.
  No LLM, no summarization, no Memory storage — just fetch and return text.

  Use with `llm_transform` for summarization or Q&A workflows:
    web_fetch → llm_transform → telegram_notify
  """
  @behaviour AlexClaw.Skill
  @impl true
  def external, do: true
  @impl true
  def description, do: "Fetches a URL and returns extracted text content (no LLM)"

  @impl true
  def routes, do: [:on_success, :on_not_found, :on_timeout, :on_error]

  require Logger
  import AlexClaw.Skills.Helpers, only: [sanitize_utf8: 1, strip_noise: 1]

  @max_content_length 8_000

  @impl true
  def step_fields, do: [:config]

  @impl true
  def config_hint, do: ~s|{"url": "https://..."} — pure fetch, no LLM|

  @impl true
  def config_scaffold, do: %{"url" => ""}

  @impl true
  def config_help,
    do:
      "url: page to fetch. Returns raw text content — no LLM, no summarization. Chain with llm_transform for processing."

  @impl true
  def run(args) do
    config = args[:config] || %{}
    url = config["url"] || to_string(args[:input] || "")

    if url == "" do
      {:error, :no_url}
    else
      case fetch_and_extract(url) do
        {:ok, content} ->
          {:ok, content, :on_success}

        {:error, {:http, 404}} ->
          {:ok, nil, :on_not_found}

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:ok, nil, :on_timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_and_extract(url) do
    headers = [
      {"user-agent", "Mozilla/5.0 (compatible; AlexClaw/1.0)"},
      {"accept", "text/html,application/xhtml+xml"}
    ]

    case Req.get(url, headers: headers, receive_timeout: 15_000, redirect: true, max_redirects: 5) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, extract_text(body)}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_text(html) do
    html
    |> sanitize_utf8()
    |> Floki.parse_document!()
    |> strip_noise()
    |> Floki.text(sep: "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.trim()
    |> String.slice(0, @max_content_length)
  end
end
