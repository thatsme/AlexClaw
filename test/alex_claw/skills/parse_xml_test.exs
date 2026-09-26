defmodule AlexClaw.Skills.ParseXmlTest do
  @moduledoc """
  A contained skill parses XML through `SkillAPI.parse_xml/2` only (S9 fix
  review, ruling on F1).

  `import SweetXml` was allowed anywhere in a skill, and after it every
  SweetXml function was a local call the checker does not look at: `parse`
  with its default options decides entity handling, the file system
  included. SweetXml is no longer importable by a contained skill.
  `SkillAPI.parse_xml/2` parses with document type declarations refused, so
  no entity — internal or external — is ever resolved, and hands back plain
  maps: `%{name:, attributes:, text:, children:}`.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.SafeExecutor
  alias AlexClaw.Skills.SkillAPI
  alias AlexClaw.Workflows.SkillRegistry

  @feed """
  <?xml version="1.0"?>
  <rss version="2.0"><channel>
    <item><title>First</title><link>https://example.com/1</link></item>
    <item><title>Second &amp; last</title><link>https://example.com/2</link></item>
  </channel></rss>
  """

  setup do
    dir = Application.get_env(:alex_claw, :skills_dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      for name <- ~w(xml_importer xml_reader), do: SkillRegistry.unload_skill(name)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "a skill importing SweetXml is refused at load", %{dir: dir} do
    File.write!(Path.join(dir, "xml_importer.ex"), """
    defmodule AlexClaw.Skills.Dynamic.XmlImporter do
      @behaviour AlexClaw.Skill
      import SweetXml
      @impl true
      def description, do: "imports SweetXml"
      @impl true
      def run(%{input: xml}), do: {:ok, parse(xml), :on_success}
    end
    """)

    assert {:error, {:forbidden_construct, construct}} =
             SkillRegistry.load_skill("xml_importer.ex")

    assert construct =~ "SweetXml"
  end

  test "parse_xml hands back the document as plain maps" do
    assert {:ok, %{name: "rss", attributes: %{"version" => "2.0"}, children: [channel]}} =
             SkillAPI.parse_xml(__MODULE__, @feed)

    assert [first, second] = channel.children
    assert %{name: "item", children: [%{name: "title", text: "First"}, %{name: "link"}]} = first
    assert %{children: [%{text: "Second & last"} | _]} = second
  end

  test "parse_xml resolves no entity, internal or external" do
    for doctype <- [
          ~s(<!DOCTYPE r [<!ENTITY x "expanded">]><r>&x;</r>),
          ~s(<!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><r>&x;</r>),
          ~s(<!DOCTYPE r SYSTEM "file:///etc/passwd"><r/>)
        ] do
      result = SkillAPI.parse_xml(__MODULE__, doctype)
      assert {:error, _reason} = result, doctype
      refute inspect(result) =~ "expanded"
      refute inspect(result) =~ "root:"
    end
  end

  test "parse_xml refuses what is not XML" do
    assert {:error, :invalid_xml} = SkillAPI.parse_xml(__MODULE__, "<unclosed>")
    assert {:error, :invalid_xml} = SkillAPI.parse_xml(__MODULE__, "not xml at all")
  end

  test "a contained skill parses a feed with it", %{dir: dir} do
    File.write!(Path.join(dir, "xml_reader.ex"), """
    defmodule AlexClaw.Skills.Dynamic.XmlReader do
      @behaviour AlexClaw.Skill
      alias AlexClaw.Skills.SkillAPI
      @impl true
      def description, do: "reads titles"
      @impl true
      def run(%{input: xml}) do
        {:ok, doc} = SkillAPI.parse_xml(__MODULE__, xml)
        {:ok, doc |> items() |> Enum.map(&title/1), :on_success}
      end

      defp items(%{name: "item"} = item), do: [item]
      defp items(%{children: children}), do: Enum.flat_map(children, &items/1)

      defp title(%{children: children}), do: Enum.find_value(children, &title_text/1)

      defp title_text(%{name: "title", text: text}), do: text
      defp title_text(_child), do: nil
    end
    """)

    assert {:ok, %{module: reader}} = SkillRegistry.load_skill("xml_reader.ex")

    assert {:ok, ["First", "Second & last"], :on_success} =
             SafeExecutor.run(reader, %{input: @feed}, :dynamic, nil, [])
  end
end
