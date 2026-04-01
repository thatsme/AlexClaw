defmodule AlexClaw.RAG.Chunker do
  @moduledoc """
  Splits text into semantically meaningful chunks for embedding.

  Strategy (in priority order):
  1. Split on markdown headers (## / ###)
  2. Split on function definitions (def/defp/defmodule)
  3. Split on double newlines (paragraph boundaries)
  4. Fall back to size-based splitting on sentence boundaries

  Each chunk overlaps the previous by a configurable number of characters
  to preserve context at boundaries.
  """

  @default_max_chars 2000
  @default_overlap_chars 200
  @chunk_threshold 2000

  @type chunk :: %{text: String.t(), index: non_neg_integer(), total: pos_integer()}
  @type opts :: [max_chars: pos_integer(), overlap_chars: pos_integer()]

  @doc "Returns true if the text is long enough to benefit from chunking."
  @spec should_chunk?(String.t()) :: boolean()
  def should_chunk?(text), do: String.length(text) > @chunk_threshold

  @doc """
  Split text into overlapping chunks using semantic boundaries.
  Returns a list of chunk maps with :text, :index, and :total fields.
  Short texts return a single chunk.
  """
  @spec chunk(String.t(), opts()) :: [chunk()]
  def chunk(text, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    overlap = Keyword.get(opts, :overlap_chars, @default_overlap_chars)

    if String.length(text) <= max_chars do
      [%{text: text, index: 0, total: 1}]
    else
      sections = split_semantic(text)
      merged = merge_sections(sections, max_chars, overlap)
      total = length(merged)

      merged
      |> Enum.with_index()
      |> Enum.map(fn {chunk_text, idx} -> %{text: chunk_text, index: idx, total: total} end)
    end
  end

  # --- Semantic splitting ---

  defp split_semantic(text) do
    cond do
      # Markdown headers
      String.contains?(text, "\n## ") or String.contains?(text, "\n### ") ->
        split_on_pattern(text, ~r/\n(?=##+ )/)

      # Elixir function definitions
      String.contains?(text, "\n  def ") or String.contains?(text, "\n  defp ") or
          String.contains?(text, "\ndefmodule ") ->
        split_on_pattern(text, ~r/\n(?=\s*(?:def |defp |defmodule ))/)

      # Paragraph breaks (double newline)
      String.contains?(text, "\n\n") ->
        String.split(text, "\n\n", trim: true)

      # Single newlines as last resort
      true ->
        split_on_sentences(text)
    end
  end

  defp split_on_pattern(text, pattern) do
    Regex.split(pattern, text, trim: true)
  end

  defp split_on_sentences(text) do
    # Split on sentence boundaries: period/exclamation/question followed by space or newline
    Regex.split(~r/(?<=[.!?])\s+/, text, trim: true)
  end

  # --- Merge small sections into chunks of appropriate size ---

  defp merge_sections(sections, max_chars, overlap) do
    sections
    |> Enum.reduce([], fn section, acc ->
      case acc do
        [] ->
          [section]

        [current | rest] ->
          candidate = current <> "\n\n" <> section

          if String.length(candidate) <= max_chars do
            [candidate | rest]
          else
            # Start new chunk with overlap from the end of current
            overlap_text = take_tail(current, overlap)
            new_chunk = overlap_text <> "\n\n" <> section
            [new_chunk, current | rest]
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp take_tail(text, chars) do
    len = String.length(text)

    if len <= chars do
      text
    else
      String.slice(text, (len - chars)..-1//1)
    end
  end
end
