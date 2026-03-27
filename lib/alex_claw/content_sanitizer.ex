defmodule AlexClaw.ContentSanitizer do
  @moduledoc """
  Sanitizes content from external skills before it flows through the workflow engine.

  Defense layers:
  1. HTML stripping — extract semantic text only (Floki-based)
  2. Size guard — enforce configurable max content length
  3. Injection heuristic — flag content containing skill names or instruction-like patterns

  The sanitizer cleans and logs but does NOT block execution. Blocking is a future
  option based on confidence thresholds and the external fuzzer results.
  """
  require Logger

  @default_max_size 10_240
  @patterns_file "/app/config/injection_patterns.json"

  @fallback_patterns [
    "ignore previous instructions",
    "disregard your system",
    "you are now",
    "act as a",
    "act as an",
    "forget your",
    "override your",
    "new instructions",
    "system prompt",
    "you are dan",
    "do anything now",
    "freed from",
    "no content filter",
    "without refusal",
    "unrestricted ai",
    "no restrictions",
    "jailbreak",
    "ignore all previous",
    "disregard all previous",
    "pretend you are",
    "simulate a",
    "enter developer mode",
    "developer mode enabled",
    "bypass your",
    "override safety",
    "ignore safety",
    "you must obey"
  ]

  @doc """
  Sanitize external content. Returns the cleaned text.
  Logs warnings if injection heuristics trigger.
  """
  @spec sanitize(any(), keyword()) :: any()
  def sanitize(content, opts \\ [])

  def sanitize(content, opts) when is_binary(content) do
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    skill_name = Keyword.get(opts, :skill, "unknown")

    cleaned = strip_html(content)

    Logger.info(
      "[ContentSanitizer] Raw input from skill '#{skill_name}' (#{byte_size(cleaned)} bytes): " <>
        String.slice(cleaned, 0, 500)
    )

    cleaned
    |> enforce_size(max_size)
    |> strip_injection(skill_name)
  end

  def sanitize(content, _opts), do: content

  defp strip_html(text) do
    if html?(text) do
      text
      |> Floki.parse_document!()
      |> Floki.filter_out("script, style, noscript, template, meta, head, svg")
      |> Floki.text(sep: " ")
      |> String.replace(~r/\s{2,}/, " ")
      |> String.trim()
    else
      text
    end
  end

  defp html?(text) do
    String.contains?(text, "<") and String.contains?(text, ">")
  end

  defp enforce_size(text, max_size) do
    if byte_size(text) > max_size do
      Logger.warning("[ContentSanitizer] Content truncated from #{byte_size(text)} to #{max_size} bytes")
      String.slice(text, 0, max_size)
    else
      text
    end
  end

  @doc """
  Load injection patterns from JSON file, falling back to built-in patterns.
  File is re-read on every call so updates take effect without restart.
  """
  def load_patterns do
    path = Application.get_env(:alex_claw, :injection_patterns_file, @patterns_file)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"patterns" => patterns}} when is_list(patterns) ->
            patterns

          {:ok, patterns} when is_list(patterns) ->
            patterns

          _ ->
            Logger.warning("[ContentSanitizer] Invalid JSON in #{path}, using fallback patterns")
            @fallback_patterns
        end

      {:error, _} ->
        @fallback_patterns
    end
  end

  defp strip_injection(text, skill_name) do
    lowered = String.downcase(text)

    # Check for instruction-like patterns — loaded from file
    patterns = load_patterns()

    pattern_hits =
      patterns
      |> Enum.filter(&String.contains?(lowered, &1))

    # Check for skill name mentions
    skill_names = skill_name_list()

    skill_hits =
      skill_names
      |> Enum.filter(&String.contains?(lowered, &1))

    if pattern_hits != [] or skill_hits != [] do
      Logger.warning(
        "[ContentSanitizer] Injection detected in content from skill '#{skill_name}'. " <>
          "Patterns: #{inspect(pattern_hits)}, Skill mentions: #{inspect(skill_hits)}. Stripping."
      )

      # Remove sentences containing injection patterns
      all_hits = pattern_hits ++ skill_hits

      {kept, stripped} =
        text
        |> String.split(~r/(?<=[.!?\n])\s+/)
        |> Enum.split_with(fn sentence ->
          low = String.downcase(sentence)
          not Enum.any?(all_hits, &String.contains?(low, &1))
        end)

      if stripped != [] do
        Logger.warning(
          "[ContentSanitizer] Stripped #{length(stripped)} sentence(s) from skill '#{skill_name}': " <>
            inspect(Enum.map(stripped, &String.slice(&1, 0, 120)))
        )
      end

      Enum.join(kept, " ")
    else
      text
    end
  end

  defp skill_name_list do
    try do
      AlexClaw.Workflows.SkillRegistry.list_skills()
    rescue
      _ -> []
    end
  end
end
