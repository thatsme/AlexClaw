defmodule AlexClaw.Knowledge.SelfAwareness do
  @moduledoc """
  Loads AlexClaw's own architecture docs, security policy, skill behaviour,
  and skill template into the knowledge base on every boot.
  Uses content hashing to skip re-embedding when files haven't changed.
  """
  require Logger

  alias AlexClaw.Knowledge

  @source_prefix "self:"
  @max_chunk_chars 3000

  @docs [
    {"ALEXCLAW_ARCHITECTURE.md", "architecture", "AlexClaw architecture and design"},
    {"SECURITY.md", "security", "AlexClaw security policy and deployment hardening"},
    {"lib/alex_claw/skill.ex", "skill_behaviour", "AlexClaw.Skill behaviour definition"},
    {"test/fixtures/skills/skill_template.ex", "skill_template",
     "Dynamic skill template with SkillAPI reference"}
  ]

  @spec load() :: :ok
  def load do
    app_dir = Application.app_dir(:alex_claw)
    priv_dir = Path.join(app_dir, "priv")
    # In release, source files are not in priv — try release root
    release_root = Path.join(app_dir, "../..")

    for {file, slug, description} <- @docs do
      path = resolve_path(file, priv_dir, release_root)

      case path do
        nil ->
          Logger.debug("SelfAwareness: #{file} not found, skipping")

        path ->
          content = File.read!(path)
          source = @source_prefix <> slug
          content_hash = content_hash(content)

          if needs_update?(source, content_hash) do
            # Remove old entries for this source
            delete_by_source(source)

            # Chunk and store
            chunks = chunk_by_section(content, @max_chunk_chars)
            total = length(chunks)

            Enum.with_index(chunks, 1)
            |> Enum.each(fn {chunk, idx} ->
              Knowledge.store(:self_awareness, chunk,
                source: source,
                metadata: %{
                  "file" => file,
                  "description" => description,
                  "chunk" => "#{idx}/#{total}",
                  "content_hash" => content_hash
                }
              )
            end)

            Logger.info("SelfAwareness: loaded #{file} (#{total} chunks)")
          else
            Logger.debug("SelfAwareness: #{file} unchanged, skipping")
          end
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("SelfAwareness loading failed: #{Exception.message(e)}")
      :ok
  end

  # --- Path resolution ---

  defp resolve_path(file, priv_dir, release_root) do
    candidates = [
      # Development: project root
      Path.join(File.cwd!(), file),
      # Release: bundled in priv/self_awareness/
      Path.join([priv_dir, "self_awareness", Path.basename(file)]),
      # Release: relative to release root
      Path.join(release_root, file)
    ]

    Enum.find(candidates, &File.exists?/1)
  end

  # --- Content hashing ---

  defp content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp needs_update?(source, new_hash) do
    import Ecto.Query

    case AlexClaw.Repo.one(
           from(e in AlexClaw.Knowledge.Entry,
             where: e.source == ^source,
             limit: 1,
             select: e.metadata
           )
         ) do
      nil -> true
      %{"content_hash" => ^new_hash} -> false
      _ -> true
    end
  end

  defp delete_by_source(source) do
    import Ecto.Query
    AlexClaw.Repo.delete_all(from(e in AlexClaw.Knowledge.Entry, where: e.source == ^source))
  end

  # --- Chunking by markdown sections ---

  defp chunk_by_section(text, max_chars) do
    text
    |> String.split(~r/\n(?=##\s)/, trim: true)
    |> Enum.flat_map(fn section ->
      if String.length(section) > max_chars do
        split_large_section(section, max_chars)
      else
        [section]
      end
    end)
    |> Enum.reject(fn s -> String.length(s) < 50 end)
  end

  defp split_large_section(text, max_chars) do
    text
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.reduce([""], fn paragraph, [current | rest] ->
      candidate = if current == "", do: paragraph, else: current <> "\n\n" <> paragraph

      if String.length(candidate) > max_chars do
        [paragraph, current | rest]
      else
        [candidate | rest]
      end
    end)
    |> Enum.reject(fn s -> String.length(s) < 50 end)
    |> Enum.reverse()
  end
end
