defmodule AlexClaw.KnowledgeDeleteTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Knowledge
  alias AlexClaw.Skills.SkillAPI
  alias AlexClaw.Workflows.SkillRegistry

  defp entry(kind, source) do
    {:ok, entry} = Knowledge.store(kind, "body for #{source}", source: source)
    entry
  end

  defp sources(kind) do
    [limit: 500, kind: to_string(kind)]
    |> Knowledge.recent()
    |> Enum.map(& &1.source)
  end

  describe "delete_by_source_prefix/2 scoping" do
    test "deletes only the matching prefix within the kind" do
      entry(:hexdocs, "https://hexdocs.pm/req/Req.html")
      entry(:hexdocs, "https://hexdocs.pm/req/Req.Steps.html")
      entry(:hexdocs, "https://hexdocs.pm/jason/Jason.html")

      assert {:ok, 2} =
               Knowledge.delete_by_source_prefix("hexdocs", "https://hexdocs.pm/req/")

      remaining = sources(:hexdocs)
      assert "https://hexdocs.pm/jason/Jason.html" in remaining
      refute Enum.any?(remaining, &String.starts_with?(&1, "https://hexdocs.pm/req/"))
    end

    test "does not cross into another kind" do
      entry(:hexdocs, "https://example.com/a")
      entry(:self_awareness, "https://example.com/a")

      assert {:ok, 1} = Knowledge.delete_by_source_prefix("hexdocs", "https://example.com/")

      assert "https://example.com/a" in sources(:self_awareness)
    end
  end

  # A prefix is data, not a pattern: % and _ must match themselves.
  describe "delete_by_source_prefix/2 LIKE escaping" do
    test "a percent in the prefix matches literally" do
      entry(:hexdocs, "pkg/100%/a")
      entry(:hexdocs, "pkg/anything/b")

      assert {:ok, 1} = Knowledge.delete_by_source_prefix("hexdocs", "pkg/100%/")

      assert "pkg/anything/b" in sources(:hexdocs)
    end

    test "an underscore in the prefix matches literally" do
      entry(:hexdocs, "pkg/a_b/one")
      entry(:hexdocs, "pkg/axb/two")

      assert {:ok, 1} = Knowledge.delete_by_source_prefix("hexdocs", "pkg/a_b/")

      assert "pkg/axb/two" in sources(:hexdocs)
    end

    test "a backslash in the prefix matches literally" do
      entry(:hexdocs, "pkg/a\\b/one")
      entry(:hexdocs, "pkg/ab/two")

      assert {:ok, 1} = Knowledge.delete_by_source_prefix("hexdocs", "pkg/a\\b/")

      assert "pkg/ab/two" in sources(:hexdocs)
    end
  end

  describe "delete_by_source_prefix/2 refuses an unscoped delete" do
    test "missing or blank kind is refused" do
      assert {:error, :invalid_scope} = Knowledge.delete_by_source_prefix(nil, "pkg/")
      assert {:error, :invalid_scope} = Knowledge.delete_by_source_prefix("", "pkg/")
    end

    test "missing or blank prefix is refused" do
      assert {:error, :invalid_scope} = Knowledge.delete_by_source_prefix("hexdocs", nil)
      assert {:error, :invalid_scope} = Knowledge.delete_by_source_prefix("hexdocs", "")
    end

    test "a blank scope deletes nothing" do
      entry(:hexdocs, "pkg/keep")

      assert {:error, :invalid_scope} = Knowledge.delete_by_source_prefix("hexdocs", "")

      assert "pkg/keep" in sources(:hexdocs)
    end
  end

  describe "SkillAPI.knowledge_delete/2" do
    # check_permission/2 reads the registry, not the module, so the skills are
    # loaded the way a real dynamic skill would be.
    setup do
      skills_dir = Application.get_env(:alex_claw, :skills_dir)
      File.mkdir_p!(skills_dir)

      File.write!(Path.join(skills_dir, "kd_writer.ex"), """
      defmodule AlexClaw.Skills.Dynamic.KdWriter do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:knowledge_write]
        @impl true
        def description, do: "writer"
        @impl true
        def run(_args), do: {:ok, "ok", :on_success}
      end
      """)

      File.write!(Path.join(skills_dir, "kd_reader.ex"), """
      defmodule AlexClaw.Skills.Dynamic.KdReader do
        @behaviour AlexClaw.Skill
        @impl true
        def permissions, do: [:knowledge_read]
        @impl true
        def description, do: "reader"
        @impl true
        def run(_args), do: {:ok, "ok", :on_success}
      end
      """)

      {:ok, _} = SkillRegistry.load_skill("kd_writer.ex")
      {:ok, _} = SkillRegistry.load_skill("kd_reader.ex")

      on_exit(fn ->
        SkillRegistry.unload_skill("kd_writer")
        SkillRegistry.unload_skill("kd_reader")
        File.rm_rf!(skills_dir)
      end)

      %{
        writer: AlexClaw.Skills.Dynamic.KdWriter,
        reader: AlexClaw.Skills.Dynamic.KdReader
      }
    end

    test "a skill holding :knowledge_write may delete", %{writer: writer} do
      entry(:hexdocs, "pkg/gone/a")

      assert {:ok, 1} =
               SkillAPI.knowledge_delete(writer, kind: "hexdocs", source_prefix: "pkg/gone/")
    end

    test "a skill without :knowledge_write is denied", %{reader: reader} do
      entry(:hexdocs, "pkg/kept/a")

      assert {:error, :permission_denied} =
               SkillAPI.knowledge_delete(reader, kind: "hexdocs", source_prefix: "pkg/kept/")

      assert "pkg/kept/a" in sources(:hexdocs)
    end

    test "the permission check runs before the scope check", %{reader: reader} do
      assert {:error, :permission_denied} =
               SkillAPI.knowledge_delete(reader, kind: nil, source_prefix: nil)
    end

    test "a permitted skill still cannot express an unscoped delete", %{writer: writer} do
      assert {:error, :invalid_scope} =
               SkillAPI.knowledge_delete(writer, kind: "hexdocs", source_prefix: nil)
    end
  end
end
