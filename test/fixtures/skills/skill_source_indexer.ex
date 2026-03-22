defmodule AlexClaw.Skills.Dynamic.SkillSourceIndexer do
  @moduledoc """
  Indexes existing AlexClaw dynamic skill source code into the knowledge base.

  The model learns idiomatic patterns by reading real, working skill implementations:
  SkillAPI usage, permission declarations, chunking strategies, error handling, etc.
  """
  @behaviour AlexClaw.Skill
  alias AlexClaw.Skills.SkillAPI

  @max_chunk_chars 3000

  @impl true
  def version, do: "1.0.0"

  @impl true
  def permissions, do: [:knowledge_read, :knowledge_write]

  @impl true
  def description, do: "Index existing skill source code into knowledge base for pattern learning"

  @impl true
  def routes, do: [:on_success, :on_empty, :on_error]

  @impl true
  def run(args) do
    config = args[:config] || %{}
    exclude = config["exclude"] || []

    skills_dir = Application.get_env(:alex_claw, :skills_dir, "/app/skills")

    case File.ls(skills_dir) do
      {:ok, files} ->
        skill_files =
          files
          |> Enum.filter(&String.ends_with?(&1, ".ex"))
          |> Enum.reject(&(&1 in exclude))

        results =
          skill_files
          |> Enum.map(fn file -> {file, index_skill_file(skills_dir, file)} end)

        total_stored = Enum.sum(Enum.map(results, fn {_f, count} -> count end))

        summary =
          results
          |> Enum.reject(fn {_f, count} -> count == 0 end)
          |> Enum.map(fn {f, count} -> "#{f}: #{count} chunks" end)
          |> Enum.join("\n")

        if total_stored > 0 do
          {:ok, "Indexed #{total_stored} chunks from #{length(skill_files)} skill files.\n\n#{summary}", :on_success}
        else
          {:ok, "No new skill source to index (#{length(skill_files)} files already stored).", :on_empty}
        end

      {:error, reason} ->
        {:error, "Cannot read skills directory #{skills_dir}: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Skill source indexer failed: #{Exception.message(e)}"}
  end

  # --- File indexing ---

  defp index_skill_file(skills_dir, file_name) do
    source_key = "skill_source:#{file_name}"

    case already_stored?(source_key) do
      true ->
        # Check if file changed by comparing checksum
        case check_freshness(skills_dir, file_name, source_key) do
          :fresh -> 0
          :stale -> reindex_file(skills_dir, file_name, source_key)
        end

      false ->
        reindex_file(skills_dir, file_name, source_key)
    end
  end

  defp reindex_file(skills_dir, file_name, source_key) do
    path = Path.join(skills_dir, file_name)

    case File.read(path) do
      {:ok, content} ->
        skill_name = String.replace(file_name, ".ex", "")
        prefixed = "AlexClaw Skill Source: #{skill_name}\n\n#{content}"
        chunks = chunk_code(prefixed, @max_chunk_chars)
        store_chunks(file_name, chunks, source_key, content)

      {:error, _} ->
        0
    end
  end

  defp already_stored?(source_key) do
    case SkillAPI.knowledge_exists?(__MODULE__, source_key) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp check_freshness(skills_dir, file_name, source_key) do
    path = Path.join(skills_dir, file_name)

    with {:ok, content} <- File.read(path),
         checksum = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
         {:ok, results} <- SkillAPI.knowledge_search(__MODULE__, source_key, limit: 1, kind: "skill_source") do
      case results do
        [%{metadata: %{"checksum" => ^checksum}} | _] -> :fresh
        _ -> :stale
      end
    else
      _ -> :stale
    end
  end

  # --- Code chunking ---

  # Split code on module/function boundaries rather than arbitrary positions
  defp chunk_code(code, max_chars) when byte_size(code) <= max_chars, do: [code]

  defp chunk_code(code, max_chars) do
    code
    |> String.split(~r/\n(?=\s*(?:defmodule|defp?\s|@impl|@moduledoc|@doc|#\s---))/, trim: true)
    |> Enum.reduce([""], fn segment, [current | rest] ->
      candidate = if current == "", do: segment, else: current <> "\n" <> segment

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

  defp store_chunks(_file, [], _source_key, _content), do: 0

  defp store_chunks(file_name, chunks, source_key, raw_content) do
    checksum = :crypto.hash(:sha256, raw_content) |> Base.encode16(case: :lower)

    chunks
    |> Enum.with_index(1)
    |> Enum.count(fn {chunk, idx} ->
      chunk_source = if idx == 1, do: source_key, else: "#{source_key}##{idx}"

      case SkillAPI.knowledge_store(
             __MODULE__,
             "skill_source",
             String.slice(chunk, 0, @max_chunk_chars),
             source: chunk_source,
             metadata: %{
               file: file_name,
               chunk_index: idx,
               checksum: checksum,
               indexed_at: DateTime.to_iso8601(DateTime.utc_now())
             }
           ) do
        {:ok, _} -> true
        _ -> false
      end
    end)
  end
end
