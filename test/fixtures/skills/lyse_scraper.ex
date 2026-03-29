defmodule AlexClaw.Skills.Dynamic.LyseScraper do
  @moduledoc """
  Scrapes Learn You Some Erlang (learnyousomeerlang.com) chapters
  and stores them as knowledge base embeddings for RAG retrieval.

  Focuses on OTP design principles, supervision, gen_server patterns,
  and other BEAM concepts critical for idiomatic code generation.
  """
  @behaviour AlexClaw.Skill
  alias AlexClaw.Skills.SkillAPI

  @max_chunk_chars 3000
  @recv_timeout 15_000
  @base_url "https://learnyousomeerlang.com"

  # OTP & concurrency chapters — highest value for code generation
  @default_chapters ~w(
    the-hitchhikers-guide-to-concurrency
    errors-and-processes
    designing-a-concurrent-application
    what-is-otp
    clients-and-servers
    rage-against-the-finite-state-machines
    event-handlers
    supervisors
    building-an-application-with-otp
    building-applications-with-otp
    the-count-of-applications
    buckets-of-sockets
    eunits
    common-test-for-uncommon-tests
    mnesia
    distribunomicon
    types-or-lack-thereof
  )

  @impl true
  def version, do: "2.0.0"

  @impl true
  def permissions, do: [:web_read, :knowledge_read, :knowledge_write]

  @impl true
  def description, do: "Scrape Learn You Some Erlang OTP chapters into knowledge base"

  @impl true
  def routes, do: [:on_success, :on_empty, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"timeout_ms": 300000, "delay_between_chapters_ms": 2000}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"timeout_ms" => 300_000, "delay_between_chapters_ms" => 2000}

  @impl true
  @spec config_help() :: String.t()
  def config_help, do: "timeout_ms: total allowed time (default 300000). delay_between_chapters_ms: pause between chapters (default 2000). discover_chapters: true to auto-discover from table of contents."

  @impl true
  def run(args) do
    config = args[:config] || %{}
    chapters = config["chapters"] || @default_chapters
    discover? = config["discover_chapters"] == true
    delay_ms = to_int(config["delay_between_chapters_ms"], 2000)
    timeout_ms = to_int(config["timeout_ms"], 300_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    chapters =
      if discover? do
        case discover_chapters() do
          {:ok, discovered} -> discovered
          {:error, _} -> chapters
        end
      else
        chapters
      end

    results =
      chapters
      |> Enum.reduce_while([], fn chapter, acc ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, [{chapter, :timeout} | acc]}
        else
          result = scrape_chapter(chapter)
          if delay_ms > 0, do: Process.sleep(delay_ms)
          {:cont, [{chapter, result} | acc]}
        end
      end)
      |> Enum.reverse()

    total_stored = Enum.sum(for {_, {:stored, n}} <- results, do: n)
    total_skipped = Enum.count(results, fn {_, r} -> r == :skipped end)
    total_failed = Enum.count(results, fn {_, r} -> match?({:failed, _}, r) end)
    total_timeout = Enum.count(results, fn {_, r} -> r == :timeout end)

    summary =
      Enum.map_join(results, "\n", fn
        {ch, {:stored, n}} -> "#{ch}: #{n} new chunks"
        {ch, :skipped} -> "#{ch}: skipped (already indexed)"
        {ch, {:failed, reason}} -> "#{ch}: failed (#{reason})"
        {ch, :timeout} -> "#{ch}: skipped (deadline reached)"
      end)

    report = "Chapters: #{length(results)} | Stored: #{total_stored} | Skipped: #{total_skipped} | Failed: #{total_failed} | Timeout: #{total_timeout}\n\n#{summary}"

    if total_stored > 0 do
      {:ok, report, :on_success}
    else
      {:ok, report, :on_empty}
    end
  rescue
    e -> {:error, "LYSE scraper failed: #{Exception.message(e)}"}
  end

  # --- Chapter discovery ---

  defp discover_chapters do
    case SkillAPI.http_get(__MODULE__, "#{@base_url}/contents", receive_timeout: @recv_timeout) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        chapters =
          Regex.scan(~r{href="/([a-z0-9-]+)"}, html)
          |> Enum.map(fn [_, slug] -> slug end)
          |> Enum.reject(fn slug -> slug in ~w(contents faq community) end)
          |> Enum.uniq()

        if chapters == [], do: {:error, :no_chapters}, else: {:ok, chapters}

      _ ->
        {:error, :fetch_failed}
    end
  end

  # --- Chapter scraping ---

  defp scrape_chapter(chapter_slug) do
    source_key = "lyse:#{chapter_slug}"

    case already_stored?(source_key) do
      true ->
        :skipped

      false ->
        case fetch_chapter(chapter_slug) do
          {:ok, text} ->
            chunks = chunk_text("LYSE — #{chapter_slug}\n\n#{text}", @max_chunk_chars)
            {:stored, store_chunks(chapter_slug, chunks, source_key)}

          {:error, reason} ->
            {:failed, inspect(reason)}
        end
    end
  end

  defp fetch_chapter(chapter_slug) do
    url = "#{@base_url}/#{chapter_slug}"

    case SkillAPI.http_get(__MODULE__, url, receive_timeout: @recv_timeout) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        text = extract_content(html)

        if String.length(text) > 100 do
          {:ok, text}
        else
          {:error, :too_short}
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp already_stored?(source_key) do
    case SkillAPI.knowledge_exists?(__MODULE__, source_key) do
      {:ok, true} -> true
      _ -> false
    end
  end

  # --- Content extraction ---

  defp extract_content(html) do
    # LYSE wraps content in <div id="content"> with article text
    # Strip HTML tags, scripts, styles, nav elements
    html
    |> extract_main_content()
    |> strip_html_tags()
    |> clean_whitespace()
  end

  defp extract_main_content(html) do
    # Try to extract just the content div
    case Regex.run(~r{<div\s+id="content"[^>]*>(.*?)</div>\s*<div\s+id="footer"}s, html) do
      [_, content] -> content
      _ ->
        # Fallback: extract body content
        case Regex.run(~r{<body[^>]*>(.*)</body>}s, html) do
          [_, body] -> body
          _ -> html
        end
    end
  end

  defp strip_html_tags(html) do
    html
    |> String.replace(~r{<script[^>]*>.*?</script>}s, "")
    |> String.replace(~r{<style[^>]*>.*?</style>}s, "")
    |> String.replace(~r{<nav[^>]*>.*?</nav>}s, "")
    |> replace_with_capture(~r{<pre[^>]*>(.*?)</pre>}s, fn code ->
      "\n```\n#{strip_tags(code)}\n```\n"
    end)
    |> replace_with_capture(~r{<h[1-6][^>]*>(.*?)</h[1-6]>}s, fn heading ->
      "\n\n## #{strip_tags(heading)}\n\n"
    end)
    |> replace_with_capture(~r{<li[^>]*>(.*?)</li>}s, fn item ->
      "- #{strip_tags(item)}\n"
    end)
    |> String.replace(~r{<br\s*/?>}, "\n")
    |> String.replace(~r{<p[^>]*>}, "\n\n")
    |> strip_tags()
  end

  defp replace_with_capture(string, regex, fun) do
    Regex.replace(regex, string, fn full_match, capture ->
      fun.(capture)
    end)
  end

  defp strip_tags(text) do
    String.replace(text, ~r{<[^>]+>}, "")
  end

  defp clean_whitespace(text) do
    text
    |> String.replace(~r{&amp;}, "&")
    |> String.replace(~r{&lt;}, "<")
    |> String.replace(~r{&gt;}, ">")
    |> String.replace(~r{&quot;}, "\"")
    |> String.replace(~r{&#39;}, "'")
    |> String.replace(~r{&nbsp;}, " ")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # --- Chunking ---

  defp chunk_text(text, max_chars) when byte_size(text) <= max_chars, do: [text]

  defp chunk_text(text, max_chars) do
    text
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.reduce([""], fn segment, [current | rest] ->
      candidate = if current == "", do: segment, else: current <> "\n\n" <> segment

      if String.length(candidate) > max_chars do
        [segment, current | rest]
      else
        [candidate | rest]
      end
    end)
    |> Enum.reject(fn s -> String.length(s) < 50 end)
    |> Enum.reverse()
  end

  # --- Storage ---

  defp to_int(nil, default), do: default
  defp to_int(val, _) when is_integer(val), do: val
  defp to_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp to_int(_, default), do: default

  defp store_chunks(_chapter, [], _source_key), do: 0

  defp store_chunks(chapter, chunks, source_key) do
    chunks
    |> Enum.with_index(1)
    |> Enum.count(fn {chunk, idx} ->
      chunk_source = if idx == 1, do: source_key, else: "#{source_key}##{idx}"

      case SkillAPI.knowledge_store(
             __MODULE__,
             "lyse",
             String.slice(chunk, 0, @max_chunk_chars),
             source: chunk_source,
             metadata: %{
               chapter: chapter,
               chunk_index: idx,
               scraped_at: DateTime.to_iso8601(DateTime.utc_now())
             }
           ) do
        {:ok, _} -> true
        _ -> false
      end
    end)
  end
end
