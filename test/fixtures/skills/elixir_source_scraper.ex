defmodule AlexClaw.Skills.Dynamic.ElixirSourceScraper do
  @moduledoc """
  Fetches Elixir stdlib source code from GitHub and stores it as knowledge
  base embeddings. The model learns idiomatic Elixir patterns by reading
  source written by the language authors themselves.

  Targets key modules: Enum, Map, Kernel, GenServer, Supervisor, Agent, Task, etc.
  """
  @behaviour AlexClaw.Skill
  alias AlexClaw.Skills.SkillAPI

  @max_chunk_chars 3000
  @recv_timeout 15_000

  @github_raw "https://raw.githubusercontent.com/elixir-lang/elixir"
  @default_branch "main"

  # Modules whose source code teaches the most about idiomatic Elixir
  @default_modules ~w(
    lib/elixir/lib/enum.ex
    lib/elixir/lib/map.ex
    lib/elixir/lib/kernel.ex
    lib/elixir/lib/gen_server.ex
    lib/elixir/lib/supervisor.ex
    lib/elixir/lib/agent.ex
    lib/elixir/lib/task.ex
    lib/elixir/lib/task/supervisor.ex
    lib/elixir/lib/stream.ex
    lib/elixir/lib/string.ex
    lib/elixir/lib/process.ex
    lib/elixir/lib/registry.ex
    lib/elixir/lib/dynamic_supervisor.ex
    lib/elixir/lib/module.ex
    lib/elixir/lib/code.ex
    lib/elixir/lib/application.ex
    lib/elixir/lib/system.ex
    lib/elixir/lib/port.ex
    lib/elixir/lib/node.ex
    lib/elixir/lib/protocol.ex
    lib/elixir/lib/inspect/algebra.ex
  )

  @impl true
  def version, do: "1.0.0"

  @impl true
  def permissions, do: [:web_read, :knowledge_read, :knowledge_write]

  @impl true
  def description, do: "Fetch Elixir stdlib source from GitHub for idiomatic pattern learning"

  @impl true
  def routes, do: [:on_success, :on_empty, :on_error]

  @impl true
  def run(args) do
    config = args[:config] || %{}
    branch = config["branch"] || @default_branch
    modules = config["modules"] || @default_modules
    max_lines = to_int(config["max_lines_per_file"], 2000)

    results =
      modules
      |> Enum.map(fn path -> {path, scrape_source(path, branch, max_lines)} end)

    total_stored = Enum.sum(Enum.map(results, fn {_p, count} -> count end))

    summary =
      results
      |> Enum.reject(fn {_p, count} -> count == 0 end)
      |> Enum.map(fn {p, count} ->
        name = Path.basename(p, ".ex")
        "#{name}: #{count} chunks"
      end)
      |> Enum.join("\n")

    if total_stored > 0 do
      {:ok, "Stored #{total_stored} Elixir source chunks from #{length(modules)} modules.\n\n#{summary}", :on_success}
    else
      {:ok, "No new Elixir source to store.", :on_empty}
    end
  rescue
    e -> {:error, "Elixir source scraper failed: #{Exception.message(e)}"}
  end

  # --- Source scraping ---

  defp scrape_source(file_path, branch, max_lines) do
    source_key = "elixir_src:#{file_path}"

    case already_stored?(source_key) do
      true ->
        0

      false ->
        case fetch_source(file_path, branch) do
          {:ok, content} ->
            content = truncate_lines(content, max_lines)
            module_name = extract_module_name(content) || Path.basename(file_path, ".ex")
            chunks = chunk_source(module_name, content)
            store_chunks(file_path, module_name, chunks, source_key)

          {:error, _} ->
            0
        end
    end
  end

  defp fetch_source(file_path, branch) do
    url = "#{@github_raw}/#{branch}/#{file_path}"

    case SkillAPI.http_get(__MODULE__, url, receive_timeout: @recv_timeout) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

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

  # --- Content processing ---

  defp extract_module_name(content) do
    case Regex.run(~r/defmodule\s+([\w.]+)\s+do/, content) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp truncate_lines(content, max_lines) do
    content
    |> String.split("\n")
    |> Enum.take(max_lines)
    |> Enum.join("\n")
  end

  # Split on function/macro definitions to keep semantic units together
  defp chunk_source(module_name, content) do
    # Extract public function definitions with their docs as semantic units
    sections = split_into_functions(content)

    sections
    |> Enum.reduce([""], fn section, [current | rest] ->
      candidate = if current == "", do: section, else: current <> "\n\n" <> section

      if String.length(candidate) > @max_chunk_chars do
        [section, current | rest]
      else
        [candidate | rest]
      end
    end)
    |> Enum.reject(fn s -> String.length(s) < 50 end)
    |> Enum.reverse()
    |> Enum.map(fn chunk ->
      "Elixir stdlib — #{module_name}\n\n#{chunk}"
    end)
  end

  defp split_into_functions(content) do
    # Split on @doc, def, defp, defmacro boundaries
    content
    |> String.split(~r/\n(?=\s*(?:@doc\s|@moduledoc\s|def\s|defp\s|defmacro\s|defmacrop\s|defguard))/, trim: true)
    |> Enum.reject(fn s -> String.trim(s) == "" end)
  end

  # --- Storage ---

  defp store_chunks(_path, _module, [], _source_key), do: 0

  defp store_chunks(file_path, module_name, chunks, source_key) do
    chunks
    |> Enum.with_index(1)
    |> Enum.count(fn {chunk, idx} ->
      chunk_source = if idx == 1, do: source_key, else: "#{source_key}##{idx}"

      case SkillAPI.knowledge_store(
             __MODULE__,
             "elixir_source",
             String.slice(chunk, 0, @max_chunk_chars),
             source: chunk_source,
             metadata: %{
               file: file_path,
               module: module_name,
               chunk_index: idx,
               scraped_at: DateTime.to_iso8601(DateTime.utc_now())
             }
           ) do
        {:ok, _} -> true
        _ -> false
      end
    end)
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
