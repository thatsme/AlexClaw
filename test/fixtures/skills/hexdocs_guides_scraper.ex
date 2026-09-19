defmodule AlexClaw.Skills.Dynamic.HexdocsGuidesScraper do
  @moduledoc """
  Scrapes hexdocs.pm guide/extra pages (README, getting started, deployment,
  mix tasks, etc.) and stores chunks as embeddings in the knowledge base.

  Complements HexdocsScraper which handles module API docs only.
  """
  @behaviour AlexClaw.Skill
  alias AlexClaw.Skills.SkillAPI
  require Logger

  @max_chunk_chars 3000
  @recv_timeout 15_000

  @default_packages ~w(
    phoenix phoenix_live_view
    ecto ecto_sql
    plug
    req
    jason
  )

  @impl true
  @spec version() :: String.t()
  def version, do: "1.0.0"

  @impl true
  @spec permissions() :: [atom()]
  def permissions, do: [:web_read, :knowledge_read, :knowledge_write]

  @impl true
  @spec description() :: String.t()
  def description, do: "Scrape hexdocs.pm guides and extras into knowledge base embeddings"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_success, :on_empty, :on_error]

  @impl true
  @spec external() :: boolean()
  def external, do: true

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint,
    do:
      ~s|{"packages": ["phoenix", "ecto", "req"], "timeout_ms": 300000, "delay_between_packages_ms": 2000}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold,
    do: %{
      "packages" => @default_packages,
      "timeout_ms" => 300_000,
      "delay_between_packages_ms" => 2000
    }

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "packages: hex package names. timeout_ms: total time (default 300s). delay_between_packages_ms: pause between packages."

  @impl true
  @spec run(map()) :: {:ok, String.t(), atom()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    packages = Enum.uniq(config["packages"] || @default_packages)
    delay_ms = to_int(config["delay_between_packages_ms"], 2000)
    deadline = System.monotonic_time(:millisecond) + to_int(config["timeout_ms"], 300_000)

    packages
    |> scrape_all(delay_ms, deadline)
    |> report()
  rescue
    e -> {:error, "HexDocs guides scraper failed: #{Exception.message(e)}"}
  end

  defp scrape_all(packages, delay_ms, deadline) do
    packages
    |> Enum.reduce_while([], &scrape_step(&1, &2, delay_ms, deadline))
    |> Enum.reverse()
  end

  defp scrape_step(pkg, acc, delay_ms, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      Logger.warning("hexdocs_guides: deadline reached at #{pkg}")
      {:halt, [{pkg, :timeout} | acc]}
    else
      result = scrape_package_guides(pkg)
      if delay_ms > 0, do: Process.sleep(delay_ms)
      {:cont, [{pkg, result} | acc]}
    end
  end

  defp report(results) do
    total_stored = Enum.sum(for {_, {:stored, n}} <- results, do: n)

    counts = [
      "Packages: #{length(results)}",
      "Stored: #{total_stored}",
      "Skipped: #{Enum.count(results, &match?({_, :skipped}, &1))}",
      "Failed: #{Enum.count(results, &match?({_, {:failed, _}}, &1))}",
      "Timeout: #{Enum.count(results, &match?({_, :timeout}, &1))}"
    ]

    text = Enum.join(counts, " | ") <> "\n\n" <> Enum.map_join(results, "\n", &package_line/1)
    {:ok, text, stored_branch(total_stored)}
  end

  defp stored_branch(0), do: :on_empty
  defp stored_branch(_total_stored), do: :on_success

  defp package_line({pkg, {:stored, n}}), do: "#{pkg}: #{n} new guide chunks"
  defp package_line({pkg, :skipped}), do: "#{pkg}: skipped (all guides already indexed)"
  defp package_line({pkg, {:failed, reason}}), do: "#{pkg}: failed (#{reason})"
  defp package_line({pkg, :timeout}), do: "#{pkg}: skipped (deadline reached)"

  defp scrape_package_guides(package) do
    case fetch_guide_ids(package) do
      {:ok, guide_ids} when guide_ids != [] ->
        stored =
          Enum.sum(Enum.map(guide_ids, fn guide_id -> scrape_guide(package, guide_id) end))

        if stored > 0, do: {:stored, stored}, else: :skipped

      {:ok, []} ->
        :skipped

      {:error, reason} ->
        {:failed, inspect(reason)}
    end
  end

  defp fetch_guide_ids(package) do
    base_url = "https://hexdocs.pm/#{package}/"
    ref_url = base_url <> "api-reference.html"

    case SkillAPI.http_get(__MODULE__, ref_url, receive_timeout: @recv_timeout, retry: false) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        case extract_sidebar_js_url(html, base_url) do
          {:ok, js_url} -> fetch_and_parse_guides(js_url)
          :error -> {:ok, []}
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

  defp fetch_and_parse_guides(js_url) do
    case SkillAPI.http_get(__MODULE__, js_url, receive_timeout: @recv_timeout, retry: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> parse_sidebar_js(body)
      _ -> {:error, :sidebar_fetch_failed}
    end
  end

  defp parse_sidebar_js(body) do
    case Regex.run(~r/sidebarNodes=(\{.+\})/, body) do
      [_, json_str] -> decode_guides(Jason.decode(json_str))
      _ -> {:error, :no_sidebar_data}
    end
  end

  defp decode_guides({:ok, data}) do
    guide_ids =
      (data["extras"] || [])
      |> Enum.map(& &1["id"])
      |> Enum.reject(&(is_nil(&1) or &1 in ["api-reference", "changelog", "license"]))

    {:ok, guide_ids}
  end

  defp decode_guides(_decoded), do: {:error, :json_parse_failed}

  defp scrape_guide(package, guide_id) do
    source_url = "hexdocs_guide:#{package}/#{guide_id}"
    fetch_guide(already_stored?(source_url), package, guide_id, source_url)
  end

  defp fetch_guide(true, _package, _guide_id, _source_url), do: 0

  defp fetch_guide(false, package, guide_id, source_url) do
    url = "https://hexdocs.pm/#{package}/#{guide_id}.html"

    case SkillAPI.http_get(__MODULE__, url, receive_timeout: @recv_timeout, retry: false) do
      {:ok, %{status: 200, body: html}} when is_binary(html) ->
        store_guide(extract_text(html), package, guide_id, source_url)

      _ ->
        0
    end
  end

  defp store_guide(text, package, guide_id, source_url) do
    if String.length(text) > 100 do
      "HexDocs Guide — #{package}/#{guide_id}\n\n#{text}"
      |> chunk_text(@max_chunk_chars)
      |> then(&store_chunks(package, guide_id, &1, source_url))
    else
      0
    end
  end

  defp already_stored?(source_url) do
    case SkillAPI.knowledge_exists?(__MODULE__, source_url) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp extract_text(html) do
    doc = Floki.parse_document!(html)

    doc
    |> Floki.find("section#content, article, .content, #content")
    |> content_sections(doc)
    |> Enum.map_join("\n\n", &(&1 |> remove_noise() |> Floki.text(sep: " ")))
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  rescue
    _ -> ""
  end

  defp content_sections([], doc), do: Floki.find(doc, "body")
  defp content_sections(sections, _doc), do: sections

  defp remove_noise(node) when is_list(node), do: Enum.map(node, &remove_noise/1)
  defp remove_noise({"script", _, _}), do: {"span", [], []}
  defp remove_noise({"style", _, _}), do: {"span", [], []}
  defp remove_noise({"nav", _, _}), do: {"span", [], []}
  defp remove_noise({tag, attrs, children}), do: {tag, attrs, Enum.map(children, &remove_noise/1)}
  defp remove_noise(other), do: other

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
    |> Enum.reject(fn s -> String.length(s) < 50 end)
    |> Enum.reverse()
  end

  defp store_chunks(package, guide_id, chunks, source_url) do
    chunks
    |> Enum.with_index(1)
    |> Enum.count(fn {chunk, idx} ->
      chunk_source = if idx == 1, do: source_url, else: "#{source_url}##{idx}"

      case SkillAPI.knowledge_store(
             __MODULE__,
             "hexdocs_guide",
             String.slice(chunk, 0, @max_chunk_chars),
             source: chunk_source,
             metadata: %{
               package: package,
               guide: guide_id,
               chunk_index: idx,
               scraped_at: DateTime.to_iso8601(DateTime.utc_now())
             }
           ) do
        {:ok, _} -> true
        _ -> false
      end
    end)
  end

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
