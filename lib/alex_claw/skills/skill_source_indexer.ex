defmodule AlexClaw.Skills.SkillSourceIndexer do
  @moduledoc """
  Indexes the source of the dynamic skills in the skills directory into the
  knowledge base, so skill generation learns from working implementations:
  SkillAPI usage, permission declarations, error handling.

  A core skill since 0.4.0: it reads the skills directory and the app config,
  which a dynamic skill — contained, whoever approved it — cannot. A file is
  re-indexed only when its content changed (a SHA-256 checksum is kept with
  each chunk).
  """
  @behaviour AlexClaw.Skill

  alias AlexClaw.Skills.SkillAPI

  @max_chunk_chars 3000
  @kind "skill_source"

  @impl true
  def version, do: "3.0.0"

  @impl true
  def description, do: "Index existing skill source code into knowledge base for pattern learning"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_success, :on_empty, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"exclude": ["skill_template.ex"]}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"exclude" => []}

  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema, do: %{"exclude" => %{type: :list, required: false}}

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do: "exclude: list of filenames to skip. Indexes all .ex files in the skills directory."

  @impl true
  def run(args) do
    exclude = (args[:config] || %{})["exclude"] || []
    dir = Application.get_env(:alex_claw, :skills_dir, "/app/skills")
    dir |> File.ls() |> listed(dir, exclude)
  end

  defp listed({:error, reason}, dir, _exclude),
    do: {:error, "Cannot read skills directory #{dir}: #{inspect(reason)}"}

  defp listed({:ok, files}, dir, exclude) do
    results =
      files
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.reject(&(&1 in exclude))
      |> Enum.map(&{&1, index_file(dir, &1)})

    results |> tally() |> result(report(results))
  end

  defp tally(results) do
    %{
      files: length(results),
      stored: Enum.sum(for {_file, {:stored, n}} <- results, do: n),
      updated: Enum.sum(for {_file, {:updated, n}} <- results, do: n),
      fresh: Enum.count(results, &match?({_file, :fresh}, &1)),
      failed: Enum.count(results, &match?({_file, {:failed, _reason}}, &1))
    }
  end

  defp report(results), do: Enum.map_join(results, "\n", &describe/1)

  defp describe({file, {:stored, n}}), do: "#{file}: #{n} new chunks"
  defp describe({file, {:updated, n}}), do: "#{file}: #{n} chunks (re-indexed, content changed)"
  defp describe({file, :fresh}), do: "#{file}: skipped (unchanged)"
  defp describe({file, {:failed, reason}}), do: "#{file}: failed (#{reason})"

  # Every file failing is a failure, not "nothing new"; some failing are named in
  # the report.
  defp result(%{files: files, failed: files} = counts, summary) when files > 0,
    do: {:error, "Every skill file failed to index.\n\n" <> headline(counts, summary)}

  defp result(%{stored: stored, updated: updated} = counts, summary)
       when stored + updated > 0,
       do: {:ok, headline(counts, summary), :on_success}

  defp result(counts, summary), do: {:ok, headline(counts, summary), :on_empty}

  defp headline(counts, summary) do
    "Files: #{counts.files} | New: #{counts.stored} | Updated: #{counts.updated} | " <>
      "Unchanged: #{counts.fresh} | Failed: #{counts.failed}\n\n#{summary}"
  end

  # --- One file ---

  defp index_file(dir, file_name) do
    source_key = "skill_source:#{file_name}"

    with {:ok, content} <- File.read(Path.join(dir, file_name)),
         {:ok, stored?} <- SkillAPI.knowledge_exists?(__MODULE__, source_key) do
      indexed(stored?, file_name, source_key, content)
    else
      {:error, reason} -> {:failed, inspect(reason)}
    end
  end

  defp indexed(false, file_name, source_key, content),
    do: tagged(store_file(file_name, source_key, content), :stored)

  defp indexed(true, file_name, source_key, content),
    do: refreshed(fresh?(source_key, content), file_name, source_key, content)

  defp refreshed(true, _file_name, _source_key, _content), do: :fresh

  defp refreshed(false, file_name, source_key, content),
    do: tagged(store_file(file_name, source_key, content), :updated)

  defp tagged(0, _tag), do: {:failed, "no chunk was stored"}
  defp tagged(n, tag), do: {tag, n}

  defp fresh?(source_key, content) do
    checksum = checksum(content)

    case SkillAPI.knowledge_search(__MODULE__, source_key, limit: 1, kind: @kind) do
      {:ok, [%{metadata: %{"checksum" => ^checksum}} | _]} -> true
      _stale_or_unknown -> false
    end
  end

  defp checksum(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  # --- Chunking: on module and function boundaries, not arbitrary positions ---

  defp store_file(file_name, source_key, content) do
    skill_name = String.replace_suffix(file_name, ".ex", "")
    chunks = chunk("AlexClaw Skill Source: #{skill_name}\n\n#{content}")
    meta = %{file: file_name, checksum: checksum(content)}

    chunks
    |> Enum.with_index(1)
    |> Enum.count(&stored?(&1, source_key, meta))
  end

  defp chunk(code) when byte_size(code) <= @max_chunk_chars, do: [code]

  defp chunk(code) do
    code
    |> String.split(~r/\n(?=\s*(?:defmodule|defp?\s|@impl|@moduledoc|@doc|#\s---))/, trim: true)
    |> Enum.reduce([""], &join_segment/2)
    |> Enum.reject(&(String.length(&1) < 30))
    |> Enum.reverse()
  end

  defp join_segment(segment, ["" | rest]), do: [segment | rest]

  defp join_segment(segment, [current | rest]),
    do: fits(current <> "\n" <> segment, segment, current, rest)

  defp fits(candidate, segment, current, rest) do
    if String.length(candidate) > @max_chunk_chars,
      do: [segment, current | rest],
      else: [candidate | rest]
  end

  defp stored?({chunk, index}, source_key, meta) do
    result =
      SkillAPI.knowledge_store(__MODULE__, @kind, String.slice(chunk, 0, @max_chunk_chars),
        source: chunk_source(source_key, index),
        metadata:
          Map.merge(meta, %{
            chunk_index: index,
            indexed_at: DateTime.to_iso8601(DateTime.utc_now())
          })
      )

    match?({:ok, _stored}, result)
  end

  defp chunk_source(source_key, 1), do: source_key
  defp chunk_source(source_key, index), do: "#{source_key}##{index}"
end
