defmodule AlexClaw.Skills.Dynamic.HexdocsScraper do
  @moduledoc """
  Scrapes hexdocs.pm documentation and stores chunks as embeddings
  in the knowledge base for RAG retrieval.

  Fetches the sidebar_items JS to discover all modules, then scrapes
  each module page, chunks by section/function, and stores in the
  knowledge_entries table via SkillAPI.
  """
  @behaviour AlexClaw.Skill
  alias AlexClaw.Skills.SkillAPI

  @max_chunk_chars 3000
  @max_concurrency 3
  @recv_timeout 15_000

  @default_packages ~w(
    phoenix phoenix_live_view phoenix_html phoenix_pubsub
    ecto ecto_sql
    plug plug_crypto
    jason req finch mint
    floki sweet_xml
    telemetry telemetry_metrics telemetry_poller
    bandit
    nimble_options nimble_pool
    gen_stage
  )

  @impl true
  def version, do: "1.0.0"

  @impl true
  def permissions, do: [:web_read, :knowledge_read, :knowledge_write]

  @impl true
  def description, do: "Scrape hexdocs.pm documentation into knowledge base embeddings"

  @impl true
  def routes, do: [:on_success, :on_empty, :on_error]

  @impl true
  def run(args) do
    config = args[:config] || %{}
    packages = config["packages"] || @default_packages
    max_modules = to_int(config["max_modules_per_package"], 50)

    results =
      packages
      |> Enum.map(fn pkg -> scrape_package(pkg, max_modules) end)

    total_stored = Enum.sum(Enum.map(results, fn {_pkg, count} -> count end))
    total_skipped = Enum.sum(Enum.map(results, fn {_pkg, _count} -> 0 end))

    summary =
      results
      |> Enum.map(fn {pkg, count} -> "#{pkg}: #{count} chunks stored" end)
      |> Enum.join("\n")

    if total_stored > 0 do
      {:ok, "Stored #{total_stored} documentation chunks.\n\n#{summary}", :on_success}
    else
      {:ok, "No new documentation found to store.", :on_empty}
    end
  rescue
    e -> {:error, "HexDocs scraper failed: #{Exception.message(e)}"}
  end

  # --- Package scraping ---

  defp scrape_package(package, max_modules) do
    case fetch_sidebar(package) do
      {:ok, modules} ->
        modules = Enum.take(modules, max_modules)

        stored =
          modules
          |> Task.async_stream(
            fn mod -> scrape_module(package, mod) end,
            max_concurrency: @max_concurrency,
            timeout: @recv_timeout + 5_000,
            on_timeout: :kill_task
          )
          |> Enum.flat_map(fn
            {:ok, {:ok, chunks}} -> chunks
            _ -> []
          end)
          |> length()

        {package, stored}

      {:error, _reason} ->
        {package, 0}
    end
  end

  defp fetch_sidebar(package) do
    base_url = "https://hexdocs.pm/#{package}/"
    # api-reference.html always exists and contains the sidebar JS
    # (the index page often redirects to readme.html which is a stub)
    ref_url = base_url <> "api-reference.html"

    case SkillAPI.http_get(__MODULE__, ref_url, receive_timeout: @recv_timeout, retry: false) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        case extract_sidebar_js_url(html, base_url) do
          {:ok, js_url} -> fetch_and_parse_sidebar(js_url)
          :error -> parse_modules_from_html(html)
        end

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_sidebar_js_url(html, base_url) do
    case Regex.run(~r/src="(dist\/sidebar_items-[^"]+\.js)"/, html) do
      [_, js_path] -> {:ok, base_url <> js_path}
      _ -> :error
    end
  end

  defp fetch_and_parse_sidebar(js_url) do
    case SkillAPI.http_get(__MODULE__, js_url, receive_timeout: @recv_timeout, retry: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        parse_sidebar_js(body)

      _ ->
        {:error, :sidebar_fetch_failed}
    end
  end

  defp parse_sidebar_js(js_body) do
    case Regex.run(~r/sidebarNodes=(\{.+\})/, js_body) do
      [_, json_str] ->
        case Jason.decode(json_str) do
          {:ok, data} ->
            module_ids =
              (data["modules"] || [])
              |> Enum.map(fn m -> m["id"] end)
              |> Enum.reject(&is_nil/1)

            guide_ids =
              (data["extras"] || [])
              |> Enum.map(fn e -> e["id"] end)
              |> Enum.reject(&is_nil/1)
              |> Enum.reject(fn id -> id == "api-reference" end)

            {:ok, module_ids ++ guide_ids}

          _ ->
            {:error, :json_parse_failed}
        end

      _ ->
        {:error, :no_sidebar_data}
    end
  end

  defp parse_modules_from_html(html) do
    doc = Floki.parse_document!(html)

    modules =
      doc
      |> Floki.find("nav#sidebar a[href]")
      |> Enum.map(fn node -> Floki.attribute(node, "href") |> List.first() end)
      |> Enum.filter(fn href -> href && String.ends_with?(href, ".html") end)
      |> Enum.map(fn href -> href |> String.replace(".html", "") end)
      |> Enum.reject(fn name -> String.starts_with?(name, "dist/") end)
      |> Enum.uniq()

    if modules == [], do: {:error, :no_modules_found}, else: {:ok, modules}
  rescue
    _ -> {:error, :html_parse_failed}
  end

  # --- Module scraping ---

  defp scrape_module(package, module_id) do
    url = "https://hexdocs.pm/#{package}/#{module_id}.html"
    source_url = url

    case already_stored?(source_url) do
      true ->
        {:ok, []}

      false ->
        case SkillAPI.http_get(__MODULE__, url, receive_timeout: @recv_timeout, retry: false) do
          {:ok, %{status: 200, body: html}} when is_binary(html) ->
            chunks = extract_and_store_chunks(package, module_id, html, source_url)
            {:ok, chunks}

          _ ->
            {:ok, []}
        end
    end
  end

  defp already_stored?(source_url) do
    case SkillAPI.knowledge_exists?(__MODULE__, source_url) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp extract_and_store_chunks(package, module_id, html, source_url) do
    doc = Floki.parse_document!(html)

    # Extract the moduledoc section
    moduledoc_chunks = extract_moduledoc(doc, package, module_id, source_url)

    # Extract function documentation sections
    function_chunks = extract_function_docs(doc, package, module_id, source_url)

    moduledoc_chunks ++ function_chunks
  rescue
    _ -> []
  end

  defp extract_moduledoc(doc, package, module_id, source_url) do
    case Floki.find(doc, "section#moduledoc") do
      [] ->
        []

      [section | _] ->
        text = section |> clean_text()

        if String.length(text) > 50 do
          chunks = chunk_text(text, @max_chunk_chars)

          Enum.with_index(chunks, 1)
          |> Enum.flat_map(fn {chunk, idx} ->
            chunk_source = if idx == 1, do: source_url, else: "#{source_url}#moduledoc-#{idx}"

            case store_chunk(package, module_id, "moduledoc", chunk, chunk_source) do
              {:ok, _} -> [chunk]
              _ -> []
            end
          end)
        else
          []
        end
    end
  end

  defp extract_function_docs(doc, package, module_id, source_url) do
    doc
    |> Floki.find("section.detail")
    |> Enum.flat_map(fn section ->
      func_id = Floki.attribute(section, "id") |> List.first() || "unknown"
      text = clean_text(section)

      if String.length(text) > 30 do
        chunk_source = "#{source_url}##{func_id}"

        case store_chunk(package, module_id, func_id, text, chunk_source) do
          {:ok, _} -> [text]
          _ -> []
        end
      else
        []
      end
    end)
  end

  defp store_chunk(package, module_id, section, content, source_url) do
    prefixed_content = "#{module_id} — #{section}\n\n#{content}"

    SkillAPI.knowledge_store(
      __MODULE__,
      "hexdocs",
      String.slice(prefixed_content, 0, @max_chunk_chars),
      source: source_url,
      metadata: %{
        package: package,
        module: module_id,
        section: section,
        scraped_at: DateTime.to_iso8601(DateTime.utc_now())
      }
    )
  end

  # --- Text extraction ---

  defp clean_text(node) do
    node
    |> remove_noise()
    |> Floki.text(sep: " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp remove_noise(node) when is_list(node) do
    Enum.map(node, &remove_noise/1)
  end

  defp remove_noise({"script", _, _}), do: {"span", [], []}
  defp remove_noise({"style", _, _}), do: {"span", [], []}

  defp remove_noise({tag, attrs, children}) do
    {tag, attrs, Enum.map(children, &remove_noise/1)}
  end

  defp remove_noise(other), do: other

  # --- Chunking ---

  defp chunk_text(text, max_chars) when byte_size(text) <= max_chars, do: [text]

  defp chunk_text(text, max_chars) do
    text
    |> String.split(~r/\n{2,}|\. (?=[A-Z])/, trim: true)
    |> Enum.reduce([""], fn segment, [current | rest] ->
      candidate = if current == "", do: segment, else: current <> " " <> segment

      if String.length(candidate) > max_chars do
        [segment, current | rest]
      else
        [candidate | rest]
      end
    end)
    |> Enum.reject(fn s -> String.length(s) < 30 end)
    |> Enum.reverse()
  end

  # --- Helpers ---

  defp to_int(nil, default), do: default
  defp to_int(val, _) when is_integer(val), do: val

  defp to_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int(_, default), do: default
end
