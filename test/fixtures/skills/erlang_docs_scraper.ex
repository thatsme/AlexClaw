defmodule AlexClaw.Skills.Dynamic.ErlangDocsScraper do
  @moduledoc """
  Fetches Erlang/OTP documentation from the erlang/otp GitHub repository
  and stores chunks as embeddings in the knowledge base for RAG retrieval.

  Uses raw markdown docs from GitHub. Falls back to EEP-48 when available.
  Each chunk includes Elixir calling convention hints so the model knows
  how to translate Erlang syntax (erlang:foo()) to Elixir (:erlang.foo()).
  """
  @behaviour AlexClaw.Skill
  require Logger
  alias AlexClaw.Skills.SkillAPI

  @max_chunk_chars 3000
  @recv_timeout 20_000
  @github_raw "https://raw.githubusercontent.com/erlang/otp/master"

  # {module_name, otp_app} — app needed for GitHub path
  @default_modules [
    # erts
    {"erlang", "erts"},
    {"atomics", "erts"},
    {"counters", "erts"},
    {"persistent_term", "erts"},
    # kernel
    {"os", "kernel"},
    {"inet", "kernel"},
    {"file", "kernel"},
    {"code", "kernel"},
    {"application", "kernel"},
    {"net_kernel", "kernel"},
    {"logger", "kernel"},
    # stdlib
    {"lists", "stdlib"},
    {"maps", "stdlib"},
    {"string", "stdlib"},
    {"timer", "stdlib"},
    {"ets", "stdlib"},
    {"calendar", "stdlib"},
    {"io", "stdlib"},
    {"io_lib", "stdlib"},
    {"re", "stdlib"},
    {"math", "stdlib"},
    {"binary", "stdlib"},
    {"sets", "stdlib"},
    {"queue", "stdlib"},
    {"rand", "stdlib"},
    {"uri_string", "stdlib"},
    {"beam_lib", "stdlib"},
    {"sys", "stdlib"},
    {"gen_server", "stdlib"},
    {"gen_statem", "stdlib"},
    {"supervisor", "stdlib"},
    {"gen_event", "stdlib"},
    {"proc_lib", "stdlib"},
    {"proplists", "stdlib"},
    {"digraph", "stdlib"},
    {"array", "stdlib"},
    # crypto
    {"crypto", "crypto"},
    # ssl
    {"ssl", "ssl"},
    # inets
    {"httpc", "inets"},
    # mnesia
    {"mnesia", "mnesia"}
  ]

  @impl true
  def version, do: "2.0.0"

  @impl true
  def permissions, do: [:web_read, :knowledge_read, :knowledge_write]

  @impl true
  def description, do: "Fetch Erlang/OTP docs from GitHub into knowledge base embeddings"

  @impl true
  def routes, do: [:on_success, :on_empty, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"timeout_ms": 300000, "delay_between_modules_ms": 1000}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"timeout_ms" => 300_000, "delay_between_modules_ms" => 1000}

  @impl true
  @spec config_help() :: String.t()
  def config_help, do: "timeout_ms: total allowed time (default 300000 = 5 min). delay_between_modules_ms: pause between modules (default 1000)."

  @impl true
  def run(args) do
    config = args[:config] || %{}
    modules = resolve_modules(config)
    delay_ms = to_int(config["delay_between_modules_ms"], 1000)
    timeout_ms = to_int(config["timeout_ms"], 300_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    results =
      modules
      |> Enum.reduce_while([], fn {mod, app}, acc ->
        if System.monotonic_time(:millisecond) >= deadline do
          Logger.warning("erlang_docs: deadline reached, stopping")
          {:halt, [{mod, :timeout} | acc]}
        else
          result = scrape_module(mod, app)
          if delay_ms > 0, do: Process.sleep(delay_ms)
          {:cont, [{mod, result} | acc]}
        end
      end)
      |> Enum.reverse()

    total_stored = Enum.sum(for {_, {:stored, n}} <- results, do: n)
    total_skipped = Enum.count(results, fn {_, r} -> r == :skipped end)
    total_failed = Enum.count(results, fn {_, r} -> match?({:failed, _}, r) end)
    total_timeout = Enum.count(results, fn {_, r} -> r == :timeout end)

    summary =
      Enum.map_join(results, "\n", fn
        {mod, {:stored, n}} -> "#{mod}: #{n} chunks stored"
        {mod, :skipped} -> "#{mod}: skipped (already indexed)"
        {mod, {:failed, reason}} -> "#{mod}: failed (#{reason})"
        {mod, :timeout} -> "#{mod}: skipped (deadline reached)"
      end)

    report = "Modules: #{length(modules)} | Stored: #{total_stored} | Skipped: #{total_skipped} | Failed: #{total_failed} | Timeout: #{total_timeout}\n\n#{summary}"

    if total_stored > 0 do
      {:ok, report, :on_success}
    else
      {:ok, report, :on_empty}
    end
  rescue
    e -> {:error, "Erlang docs scraper failed: #{Exception.message(e)}"}
  end

  # --- Module resolution ---

  defp resolve_modules(config) do
    case config["modules"] do
      mods when is_list(mods) ->
        Enum.map(mods, fn
          %{"name" => name, "app" => app} -> {name, app}
          name when is_binary(name) -> find_app(name)
        end)

      _ ->
        @default_modules
    end
  end

  defp find_app(name) do
    case Enum.find(@default_modules, fn {n, _} -> n == name end) do
      {_, app} -> {name, app}
      nil -> {name, "stdlib"}
    end
  end

  # --- Module scraping ---

  defp scrape_module(mod_name, app) do
    source_key = "erlang_docs:#{mod_name}"

    case already_stored?(source_key) do
      true -> :skipped
      false -> do_scrape(mod_name, app, source_key)
    end
  end

  defp do_scrape(mod_name, app, source_key) do
    case try_eep48(mod_name) do
      {:ok, chunks} when chunks != [] ->
        {:stored, store_chunks(mod_name, chunks, source_key)}

      _ ->
        case fetch_from_github(mod_name, app) do
          {:ok, chunks} ->
            {:stored, store_chunks(mod_name, chunks, source_key)}

          {:error, reason} ->
            Logger.warning("erlang_docs: #{mod_name} failed: #{inspect(reason)}")
            {:failed, inspect(reason)}
        end
    end
  end

  defp already_stored?(source_key) do
    case SkillAPI.knowledge_exists?(__MODULE__, source_key) do
      {:ok, true} -> true
      _ -> false
    end
  end

  # --- EEP-48 extraction ---

  defp try_eep48(mod_name) do
    module = String.to_atom(mod_name)

    case :code.get_doc(module) do
      {:docs_v1, _anno, _lang, format, moduledoc, _meta, func_docs} ->
        mod_text = extract_doc_text(moduledoc, format)

        funcs =
          func_docs
          |> Enum.filter(fn
            {{kind, _, _}, _, _, doc, _} ->
              kind in [:function, :macro] and doc != :hidden and doc != :none
            _ ->
              false
          end)
          |> Enum.map(fn {{_kind, name, arity}, _anno, signatures, doc, _meta} ->
            sig = Enum.join(signatures, ", ")
            desc = extract_doc_text(doc, format)
            header = ":#{mod_name}.#{name}/#{arity}"
            sig_line = if sig != "", do: "\nSignature: #{sig}", else: ""
            desc_line = if desc, do: "\n#{desc}", else: ""
            "#{header}#{sig_line}#{desc_line}"
          end)

        chunks = build_chunks(mod_name, mod_text, funcs)
        {:ok, chunks}

      _ ->
        :unavailable
    end
  end

  defp extract_doc_text(:none, _), do: nil
  defp extract_doc_text(:hidden, _), do: nil
  defp extract_doc_text(%{"en" => text}, _), do: text
  defp extract_doc_text(text, _) when is_binary(text), do: text
  defp extract_doc_text(_, _), do: nil

  # --- GitHub fetch ---

  defp fetch_from_github(mod_name, app) do
    # Most OTP modules have docs as -doc attributes in .erl source files
    # A few have standalone .md docs in doc/src/
    # For erts, source is in erts/emulator/beam/ or erts/preloaded/src/
    urls = source_urls(mod_name, app)
    fetch_first_success(urls, mod_name)
  end

  defp source_urls(mod_name, "erts") do
    [
      "#{@github_raw}/erts/preloaded/src/#{mod_name}.erl",
      "#{@github_raw}/erts/doc/src/#{mod_name}.md"
    ]
  end

  defp source_urls(mod_name, app) do
    [
      "#{@github_raw}/lib/#{app}/src/#{mod_name}.erl",
      "#{@github_raw}/lib/#{app}/doc/src/#{mod_name}.md"
    ]
  end

  defp fetch_first_success([], _mod_name), do: {:error, :not_found}

  defp fetch_first_success([url | rest], mod_name) do
    case SkillAPI.http_get(__MODULE__, url, receive_timeout: @recv_timeout) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 200 ->
        text = if String.ends_with?(url, ".erl"), do: extract_erl_docs(body), else: body
        chunks = chunk_and_prefix(mod_name, text)

        if chunks != [] do
          {:ok, chunks}
        else
          fetch_first_success(rest, mod_name)
        end

      _ ->
        fetch_first_success(rest, mod_name)
    end
  end

  # Extract -doc attributes and -spec from .erl source
  defp extract_erl_docs(source) do
    # Extract module doc
    mod_doc =
      case Regex.run(~r/-moduledoc\s+"""(.*?)"""/s, source) do
        [_, doc] -> doc
        _ ->
          case Regex.run(~r/-moduledoc\s+"(.*?)"\./s, source) do
            [_, doc] -> doc
            _ -> ""
          end
      end

    # Extract function docs: -doc + -spec pairs
    func_docs =
      Regex.scan(~r/(?:-doc\s+"""(.*?)"""\.|-doc\s+"(.*?)"\.)(?:\s*-spec\s+(.*?)\.\n)?/s, source)
      |> Enum.map(fn
        [_, triple_doc, "", spec] -> String.trim(triple_doc) <> "\n" <> String.trim(spec)
        [_, "", single_doc, spec] -> String.trim(single_doc) <> "\n" <> String.trim(spec)
        [_, triple_doc, ""] -> String.trim(triple_doc)
        [_, "", single_doc] -> String.trim(single_doc)
        [_, triple_doc] -> String.trim(triple_doc)
        _ -> ""
      end)
      |> Enum.reject(fn s -> String.length(s) < 20 end)

    [mod_doc | func_docs]
    |> Enum.reject(fn s -> s == "" end)
    |> Enum.join("\n\n---\n\n")
  end

  # --- Chunking ---

  defp chunk_and_prefix(mod_name, text) do
    header = ":#{mod_name} — Erlang/OTP docs\nIn Elixir, call as: :#{mod_name}.function_name(args)\n\n"

    text
    |> chunk_text(@max_chunk_chars - byte_size(header))
    |> Enum.map(fn chunk -> header <> chunk end)
  end

  defp build_chunks(mod_name, mod_text, func_texts) do
    header = "In Elixir, call as: :#{mod_name}.function_name(args)\n\n"

    mod_chunks =
      if mod_text && String.length(mod_text) > 50 do
        prefixed = ":#{mod_name} — moduledoc\n#{header}#{mod_text}"
        chunk_text(prefixed, @max_chunk_chars)
      else
        []
      end

    func_chunks = group_func_chunks(mod_name, func_texts)

    mod_chunks ++ func_chunks
  end

  defp group_func_chunks(_mod, []), do: []

  defp group_func_chunks(mod_name, func_texts) do
    func_texts
    |> Enum.reduce([""], fn entry, [current | rest] ->
      candidate = if current == "", do: entry, else: current <> "\n\n" <> entry

      if String.length(candidate) > @max_chunk_chars do
        [entry, current | rest]
      else
        [candidate | rest]
      end
    end)
    |> Enum.reject(fn s -> String.length(s) < 30 end)
    |> Enum.reverse()
    |> Enum.map(fn chunk -> ":#{mod_name} — functions\n\n#{chunk}" end)
  end

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
    |> Enum.reject(fn s -> String.length(s) < 30 end)
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

  defp store_chunks(_mod, [], _source_key), do: 0

  defp store_chunks(mod_name, chunks, source_key) do
    chunks
    |> Enum.with_index(1)
    |> Enum.count(fn {chunk, idx} ->
      chunk_source = if idx == 1, do: source_key, else: "#{source_key}##{idx}"

      case SkillAPI.knowledge_store(
             __MODULE__,
             "erlang_docs",
             String.slice(chunk, 0, @max_chunk_chars),
             source: chunk_source,
             metadata: %{
               module: mod_name,
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
