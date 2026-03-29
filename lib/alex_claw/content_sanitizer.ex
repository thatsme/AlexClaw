defmodule AlexClaw.ContentSanitizer do
  @moduledoc """
  Sanitizes content from external skills before it flows through the workflow engine.

  Defense layers:
  1. Hidden HTML extraction — detect and log content in display:none, visibility:hidden,
     font-size:0, noscript, template, and other hiding techniques before stripping
  2. Zero-width unicode removal — strip steganographic characters used to hide instructions
  3. HTML stripping — extract semantic text only (Floki-based)
  4. Size guard — enforce configurable max content length
  5. Pattern matching — known injection phrases loaded from JSON at runtime
  6. Imperative tone heuristic — detect directive language (second person + imperative verbs)
     that doesn't match the surrounding content register
  7. Skill name mentions — flag external content referencing internal skill names
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

  # Zero-width and invisible unicode characters used for steganographic injection
  @zero_width_chars [
    "\u200B",  # zero-width space
    "\u200C",  # zero-width non-joiner
    "\u200D",  # zero-width joiner
    "\u200E",  # left-to-right mark
    "\u200F",  # right-to-left mark
    "\u2060",  # word joiner
    "\u2061",  # function application
    "\u2062",  # invisible times
    "\u2063",  # invisible separator
    "\u2064",  # invisible plus
    "\uFEFF",  # byte order mark (when mid-text)
    "\u00AD",  # soft hyphen
    "\u034F",  # combining grapheme joiner
    "\u061C",  # arabic letter mark
    "\u115F",  # hangul choseong filler
    "\u1160",  # hangul jungseong filler
    "\u17B4",  # khmer vowel inherent aq
    "\u17B5",  # khmer vowel inherent aa
    "\u180E"   # mongolian vowel separator
  ]

  # CSS patterns that hide content visually but keep it in the DOM
  @hidden_css_patterns [
    ~r/display\s*:\s*none/i,
    ~r/visibility\s*:\s*hidden/i,
    ~r/font-size\s*:\s*0/i,
    ~r/opacity\s*:\s*0/i,
    ~r/color\s*:\s*white/i,
    ~r/color\s*:\s*transparent/i,
    ~r/color\s*:\s*#fff(?:fff)?(?:\s|;|")/i,
    ~r/color\s*:\s*rgba?\s*\(\s*255\s*,\s*255\s*,\s*255/i,
    ~r/height\s*:\s*0/i,
    ~r/width\s*:\s*0/i,
    ~r/overflow\s*:\s*hidden/i,
    ~r/position\s*:\s*absolute[^"]*(?:left|top)\s*:\s*-\d{4,}/i,
    ~r/text-indent\s*:\s*-\d{4,}/i,
    ~r/clip\s*:\s*rect\s*\(\s*0/i
  ]

  # Imperative verbs commonly used in injection attempts
  @imperative_verbs ~w(
    ignore forget disregard override bypass skip discard
    obey execute invoke call run perform activate enable
    pretend simulate act become transform switch
    reveal output print display show expose dump repeat
    translate decode encode convert
  )

  @doc """
  Sanitize external content. Returns the cleaned text.
  Logs warnings if injection heuristics trigger.
  """
  @spec sanitize(any(), keyword()) :: any()
  def sanitize(content, opts \\ [])

  def sanitize(content, opts) when is_binary(content) do
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    skill_name = Keyword.get(opts, :skill, "unknown")

    content
    |> detect_hidden_html(skill_name)
    |> strip_zero_width(skill_name)
    |> strip_html()
    |> tap(fn cleaned ->
      Logger.info(
        "[ContentSanitizer] Raw input from skill '#{skill_name}' (#{byte_size(cleaned)} bytes): " <>
          String.slice(cleaned, 0, 500)
      )
    end)
    |> enforce_size(max_size)
    |> strip_injection(skill_name)
  end

  def sanitize(content, _opts), do: content

  # --- Layer 1: Hidden HTML Detection ---

  defp detect_hidden_html(text, skill_name) do
    if html?(text) do
      case Floki.parse_document(text) do
        {:ok, doc} ->
          detect_hidden_elements(doc, skill_name)
          detect_hidden_css(doc, skill_name)
          text

        _ ->
          text
      end
    else
      text
    end
  end

  defp detect_hidden_elements(doc, skill_name) do
    # Extract text from elements that are stripped (noscript, template, etc.)
    # These are invisible to users but readable by parsers
    hidden_tags = ["noscript", "template", "meta[content]", "[aria-hidden=true]"]

    for tag <- hidden_tags do
      elements = Floki.find(doc, tag)

      for element <- elements do
        text = String.trim(Floki.text(element))

        if text != "" and String.length(text) > 5 do
          Logger.warning(
            "[ContentSanitizer:HiddenHTML] Hidden content in <#{tag}> from skill '#{skill_name}': " <>
              String.slice(text, 0, 200)
          )
        end
      end
    end
  end

  defp detect_hidden_css(doc, skill_name) do
    # Find elements with inline styles that hide content
    styled = Floki.find(doc, "[style]")

    for element <- styled do
      style = List.first(Floki.attribute(element, "style")) || ""

      if Enum.any?(@hidden_css_patterns, &Regex.match?(&1, style)) do
        text = String.trim(Floki.text(element))

        if text != "" do
          Logger.warning(
            "[ContentSanitizer:HiddenCSS] CSS-hidden content from skill '#{skill_name}' " <>
              "(style: #{String.slice(style, 0, 80)}): #{String.slice(text, 0, 200)}"
          )
        end
      end
    end
  end

  # --- Layer 2: Zero-Width Unicode Stripping ---

  defp strip_zero_width(text, skill_name) do
    # Check for zero-width characters before stripping
    found = Enum.filter(@zero_width_chars, &String.contains?(text, &1))

    if found != [] do
      graphemes = String.graphemes(text)
      count = Enum.sum(for char <- found, do: Enum.count(graphemes, &(&1 == char)))

      Logger.warning(
        "[ContentSanitizer:Unicode] #{count} zero-width character(s) stripped from skill '#{skill_name}'. " <>
          "Types: #{inspect(Enum.map(found, &inspect_codepoint/1))}"
      )

      Enum.reduce(@zero_width_chars, text, fn char, acc ->
        String.replace(acc, char, "")
      end)
    else
      text
    end
  end

  defp inspect_codepoint(char) do
    <<cp::utf8>> = char
    "U+#{String.pad_leading(Integer.to_string(cp, 16), 4, "0")}"
  end

  # --- Layer 3: HTML Stripping ---

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

  # --- Layer 4: Size Guard ---

  defp enforce_size(text, max_size) do
    if byte_size(text) > max_size do
      Logger.warning("[ContentSanitizer] Content truncated from #{byte_size(text)} to #{max_size} bytes")
      String.slice(text, 0, max_size)
    else
      text
    end
  end

  # --- Layer 5-7: Pattern Matching + Imperative Tone + Skill Names ---

  @doc """
  Load injection patterns from JSON file, falling back to built-in patterns.
  File is re-read on every call so updates take effect without restart.
  """
  @spec load_patterns() :: [Regex.t()]
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
    sentences = String.split(text, ~r/(?<=[.!?\n])\s+/)

    # Analyze each sentence for all heuristics
    {kept, stripped_with_reasons} =
      sentences
      |> Enum.reduce({[], []}, fn sentence, {keep, strip} ->
        reasons = analyze_sentence(sentence, skill_name)

        if reasons == [] do
          {[sentence | keep], strip}
        else
          {keep, [{sentence, reasons} | strip]}
        end
      end)
      |> then(fn {k, s} -> {Enum.reverse(k), Enum.reverse(s)} end)

    if stripped_with_reasons != [] do
      Logger.warning(
        "[ContentSanitizer] Stripped #{length(stripped_with_reasons)} sentence(s) from skill '#{skill_name}':"
      )

      for {sentence, reasons} <- stripped_with_reasons do
        Logger.warning(
          "[ContentSanitizer]   [#{Enum.join(reasons, ", ")}] #{String.slice(sentence, 0, 120)}"
        )
      end
    end

    Enum.join(kept, " ")
  end

  defp analyze_sentence(sentence, _skill_name) do
    low = String.downcase(sentence)
    reasons = []

    # Check pattern match (Layer 5)
    patterns = load_patterns()

    reasons =
      if Enum.any?(patterns, &String.contains?(low, &1)) do
        ["pattern" | reasons]
      else
        reasons
      end

    # Check imperative tone (Layer 6)
    reasons =
      if imperative_tone?(sentence) do
        ["imperative" | reasons]
      else
        reasons
      end

    # Check skill name mentions (Layer 7)
    skill_names = skill_name_list()

    reasons =
      if Enum.any?(skill_names, &String.contains?(low, &1)) do
        ["skill_mention" | reasons]
      else
        reasons
      end

    Enum.reverse(reasons)
  end

  # --- Imperative Tone Detection ---

  defp imperative_tone?(sentence) do
    low = String.downcase(String.trim(sentence))

    # Must have directive markers to be considered imperative
    has_directive_target = Regex.match?(~r/\b(you|your|the ai|the model|the assistant|the system)\b/, low)
    has_imperative_verb = Enum.any?(@imperative_verbs, &Regex.match?(imperative_regex(&1), low))

    # Sentence starts with an imperative verb (direct command)
    starts_with_imperative = Enum.any?(@imperative_verbs, fn verb ->
      String.starts_with?(low, verb <> " ") or String.starts_with?(low, verb <> ",")
    end)

    # Must have both directive target + imperative verb, OR start with imperative verb
    (has_directive_target and has_imperative_verb) or starts_with_imperative
  end

  defp imperative_regex(verb) do
    ~r/\b#{Regex.escape(verb)}\b/
  end

  # --- Helpers ---

  defp skill_name_list do
    try do
      AlexClaw.Workflows.SkillRegistry.list_skills()
    rescue
      _ -> []
    end
  end
end
