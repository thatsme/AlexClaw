defmodule AlexClaw.Skills.Dynamic.HexdocsScraper do
  @moduledoc """
  Scrapes hexdocs.pm documentation and stores chunks as embeddings
  in the knowledge base for RAG retrieval.

  Fetches the sidebar_items JS to discover all modules, then scrapes
  each module page, chunks by section/function, and stores in the
  knowledge_entries table via SkillAPI.
  """
  @behaviour AlexClaw.Skill
  require Logger
  alias AlexClaw.Skills.SkillAPI

  @max_chunk_chars 3000
  @max_concurrency 3
  @recv_timeout 15_000

  @default_packages ~w(
    phoenix phoenix_live_view phoenix_html phoenix_pubsub
    ecto ecto_sql postgrex decimal
    plug plug_crypto
    jason req finch mint
    floki sweet_xml
    telemetry telemetry_metrics telemetry_poller
    bandit
    nimble_options nimble_pool nimble_totp
    quantum gen_stage
    nostrum
    pgvector
    timex csv tz yaml_elixir
  )

  @impl true
  def version, do: "3.1.0"

  @impl true
  def permissions, do: [:web_read, :knowledge_read, :knowledge_write]

  @impl true
  def description, do: "Scrape hexdocs.pm documentation into knowledge base embeddings"

  @impl true
  def routes, do: [:on_success, :on_empty, :on_error]

  @impl true
  def step_fields, do: [:config]

  @impl true
  def config_hint,
    do:
      ~s|{"packages": ["phoenix", "ecto", "req"], "force": false, "max_modules_per_package": 50, "delay_between_packages_ms": 2000, "timeout_ms": 300000}|

  @impl true
  def config_scaffold do
    %{
      "packages" => @default_packages,
      "force" => false,
      "max_modules_per_package" => 50,
      "delay_between_packages_ms" => 2000,
      "timeout_ms" => 300_000
    }
  end

  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema do
    %{
      "packages" => %{type: :list, required: false},
      "force" => %{type: :boolean, required: false},
      "max_modules_per_package" => %{type: :integer, required: false},
      "delay_between_packages_ms" => %{type: :integer, required: false},
      "timeout_ms" => %{type: :integer, required: false}
    }
  end

  @impl true
  def config_help,
    do:
      "packages: hex package names to scrape. max_modules_per_package: cap per package. delay_between_packages_ms: pause between packages (default 2000). timeout_ms: total allowed time (default 300000 = 5 min)."

  @impl true
  def run(args) do
    config = args[:config] || %{}
    packages = Enum.uniq(config["packages"] || @default_packages)
    max_modules = to_int(config["max_modules_per_package"], 50)
    delay_ms = to_int(config["delay_between_packages_ms"], 2000)
    deadline = System.monotonic_time(:millisecond) + to_int(config["timeout_ms"], 300_000)

    maybe_purge(packages, config["force"] == true)

    packages
    |> scrape_all(max_modules, delay_ms, deadline)
    |> report()
  rescue
    e -> {:error, "HexDocs scraper failed: #{Exception.message(e)}"}
  end

  defp maybe_purge(_packages, false), do: :ok

  defp maybe_purge(packages, true) do
    Enum.each(packages, fn pkg ->
      delete_package_entries(pkg)
      Logger.info("hexdocs: force mode — deleted existing entries for #{pkg}")
    end)
  end

  defp scrape_all(packages, max_modules, delay_ms, deadline) do
    packages
    |> Enum.reduce_while([], &scrape_step(&1, &2, max_modules, delay_ms, deadline))
    |> Enum.reverse()
  end

  defp scrape_step(pkg, acc, max_modules, delay_ms, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      Logger.warning("hexdocs: deadline reached, stopping at #{pkg}")
      {:halt, [{pkg, :timeout} | acc]}
    else
      result = scrape_package(pkg, max_modules)
      if delay_ms > 0, do: Process.sleep(delay_ms)
      {:cont, [{pkg, result} | acc]}
    end
  end

  defp report(results) do
    total_stored = Enum.sum(for {_, {:stored, n, _failed}} <- results, do: n)

    counts = [
      "Packages: #{length(results)}",
      "Stored: #{total_stored}",
      "Skipped: #{Enum.count(results, &match?({_, :skipped}, &1))}",
      "Failed: #{Enum.count(results, &match?({_, {:failed, _}}, &1))}",
      "Timeout: #{Enum.count(results, &match?({_, :timeout}, &1))}"
    ]

    text = Enum.join(counts, " | ") <> "\n\n" <> Enum.map_join(results, "\n", &package_line/1)
    outcome(fetched(results), text, total_stored)
  end

  # Every package it tried failing is a failure, not "nothing new"; some failing
  # are named in the text.
  defp fetched(results),
    do: for({_, r} <- results, match?({:stored, _, _}, r) or match?({:failed, _}, r), do: r)

  defp outcome([_ | _] = fetched, text, total_stored) do
    if Enum.all?(fetched, &match?({:failed, _}, &1)),
      do: {:error, "Every package failed.\n\n" <> text},
      else: {:ok, text, stored_branch(total_stored)}
  end

  defp outcome([], text, total_stored), do: {:ok, text, stored_branch(total_stored)}

  defp stored_branch(0), do: :on_empty
  defp stored_branch(_total_stored), do: :on_success

  defp package_line({pkg, {:stored, n, []}}), do: "#{pkg}: #{n} new chunks"

  defp package_line({pkg, {:stored, n, failed}}),
    do: "#{pkg}: #{n} new chunks; failed: #{Enum.join(failed, ", ")}"

  defp package_line({pkg, :skipped}),
    do: "#{pkg}: skipped (nothing new: modules already indexed or without docs)"

  defp package_line({pkg, {:failed, reason}}), do: "#{pkg}: failed (#{reason})"
  defp package_line({pkg, :timeout}), do: "#{pkg}: skipped (deadline reached)"

  # --- Package scraping ---

  defp scrape_package(package, max_modules) do
    case fetch_sidebar(package) do
      {:ok, modules} ->
        modules = Enum.take(modules, max_modules)

        modules
        |> Task.async_stream(
          fn mod -> scrape_module(package, mod) end,
          max_concurrency: @max_concurrency,
          timeout: @recv_timeout + 5_000,
          on_timeout: :kill_task
        )
        |> Enum.zip(modules)
        |> Enum.map(fn {result, mod} -> {mod, module_result(result)} end)
        |> package_result()

      {:error, reason} ->
        {:failed, inspect(reason)}
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
      [_, json_str] -> decode_sidebar(Jason.decode(json_str))
      _ -> {:error, :no_sidebar_data}
    end
  end

  defp decode_sidebar({:ok, data}) do
    module_ids = ids(data["modules"])
    guide_ids = Enum.reject(ids(data["extras"]), &(&1 == "api-reference"))

    {:ok, module_ids ++ guide_ids}
  end

  defp decode_sidebar(_decoded), do: {:error, :json_parse_failed}

  defp ids(entries) do
    (entries || [])
    |> Enum.map(& &1["id"])
    |> Enum.reject(&is_nil/1)
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

  defp module_result({:ok, result}), do: result
  defp module_result({:exit, reason}), do: {:failed, "stopped: #{inspect(reason)}"}

  # A package whose modules all failed is a failure, not "already indexed";
  # modules that failed next to stored ones are named.
  defp package_result(modules) do
    stored = Enum.sum(for {_, {:stored, n}} <- modules, do: n)
    failed = for {mod, {:failed, why}} <- modules, do: "#{mod} (#{why})"
    package_outcome(stored, failed)
  end

  defp package_outcome(0, []), do: :skipped

  defp package_outcome(0, failed),
    do: {:failed, "every module failed: " <> Enum.join(failed, ", ")}

  defp package_outcome(stored, failed), do: {:stored, stored, failed}

  # {:stored, n}, :indexed (already in the knowledge base), :no_content, or
  # {:failed, reason}.
  defp scrape_module(package, module_id) do
    url = "https://hexdocs.pm/#{package}/#{module_id}.html"
    fetch_module(SkillAPI.knowledge_exists?(__MODULE__, url), package, module_id, url)
  end

  defp fetch_module({:ok, true}, _package, _module_id, _url), do: :indexed

  defp fetch_module({:error, reason}, _package, _module_id, _url),
    do: {:failed, "cannot check the knowledge base: #{inspect(reason)}"}

  defp fetch_module({:ok, false}, package, module_id, url) do
    case SkillAPI.http_get(__MODULE__, url, receive_timeout: @recv_timeout, retry: false) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        module_stored(extract_and_store_chunks(package, module_id, html, url))

      {:ok, %{status: status}} ->
        {:failed, "http #{status}"}

      {:error, reason} ->
        {:failed, inspect(reason)}
    end
  end

  defp module_stored({:error, :html_parse_failed}), do: {:failed, "the page could not be parsed"}
  defp module_stored([]), do: :no_content
  defp module_stored(chunks), do: {:stored, length(chunks)}

  defp extract_and_store_chunks(package, module_id, html, source_url) do
    doc = Floki.parse_document!(html)

    # Extract the moduledoc section
    moduledoc_chunks = extract_moduledoc(doc, package, module_id, source_url)

    # Extract function documentation sections
    function_chunks = extract_function_docs(doc, package, module_id, source_url)

    moduledoc_chunks ++ function_chunks
  rescue
    _ -> {:error, :html_parse_failed}
  end

  defp extract_moduledoc(doc, package, module_id, source_url) do
    case Floki.find(doc, "section#moduledoc") do
      [section | _] -> moduledoc_chunks(clean_text(section), package, module_id, source_url)
      [] -> []
    end
  end

  defp moduledoc_chunks(text, package, module_id, source_url) do
    if String.length(text) > 50 do
      text
      |> chunk_text(@max_chunk_chars)
      |> Enum.with_index(1)
      |> Enum.flat_map(&store_moduledoc_chunk(&1, package, module_id, source_url))
    else
      []
    end
  end

  defp store_moduledoc_chunk({chunk, idx}, package, module_id, source_url) do
    chunk_source = if idx == 1, do: source_url, else: "#{source_url}#moduledoc-#{idx}"

    case store_chunk(package, module_id, "moduledoc", chunk, chunk_source) do
      {:ok, _} -> [chunk]
      _ -> []
    end
  end

  defp extract_function_docs(doc, package, module_id, source_url) do
    doc
    |> Floki.find("section.detail")
    |> Enum.flat_map(&store_function_doc(&1, package, module_id, source_url))
  end

  defp store_function_doc(section, package, module_id, source_url) do
    func_id = section |> Floki.attribute("id") |> List.first() || "unknown"
    text = clean_text(section)

    if String.length(text) > 30 do
      stored_text(
        store_chunk(package, module_id, func_id, text, "#{source_url}##{func_id}"),
        text
      )
    else
      []
    end
  end

  defp stored_text({:ok, _entry}, text), do: [text]
  defp stored_text(_result, _text), do: []

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

  # --- Force re-scrape ---

  defp delete_package_entries(package) do
    SkillAPI.knowledge_delete(__MODULE__,
      kind: "hexdocs",
      source_prefix: "https://hexdocs.pm/#{package}/"
    )
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
