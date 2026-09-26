defmodule AlexClaw.Skills.SafeXml do
  @moduledoc """
  XML parsing for skills, with no entity ever resolved (S9 fix review, F1).

  A document type declaration is refused before parsing, and the parser is
  run with DTD processing off (`dtd: :none`), so neither an internal entity
  nor an external one — a file, a URL — is expanded or fetched. The
  document comes back as plain maps, which contained code can walk without
  any XML library: `%{name:, attributes:, text:, children:}`, where `text` is
  the element's own text, `attributes` a map of strings, and `children` its
  child elements in order.
  """
  require Record

  Record.defrecordp(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_attribute,
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  @typedoc "An element, as a skill is given it."
  @type element :: %{
          name: String.t(),
          attributes: %{String.t() => String.t()},
          text: String.t(),
          children: [element()]
        }

  @doctype ~r/<!(DOCTYPE|ENTITY)/i

  @doc """
  `xml` as an element tree, or `{:error, :doctype_refused}` for a document
  that declares a document type or an entity, `{:error, :invalid_xml}` for
  one that does not parse.
  """
  @spec parse(String.t()) :: {:ok, element()} | {:error, :doctype_refused | :invalid_xml}
  def parse(xml) when is_binary(xml), do: parse_unless_doctype(Regex.match?(@doctype, xml), xml)

  def parse(_xml), do: {:error, :invalid_xml}

  defp parse_unless_doctype(true, _xml), do: {:error, :doctype_refused}
  defp parse_unless_doctype(false, xml), do: xml |> scanned() |> as_tree()

  # The boundary with untrusted input: xmerl raises or exits on a document it
  # cannot read, and that is an answer here, not a crash.
  defp scanned(xml) do
    {:ok, SweetXml.parse(xml, dtd: :none, quiet: true)}
  rescue
    _error -> {:error, :invalid_xml}
  catch
    :exit, _reason -> {:error, :invalid_xml}
  end

  defp as_tree({:ok, root}), do: {:ok, element(root)}
  defp as_tree(error), do: error

  defp element(xml_element(name: name, attributes: attributes, content: content)) do
    %{
      name: to_string(name),
      attributes: Map.new(attributes, &attribute/1),
      text: content |> Enum.filter(&text?/1) |> Enum.map_join(&text/1),
      children: content |> Enum.filter(&element?/1) |> Enum.map(&element/1)
    }
  end

  defp attribute(xml_attribute(name: name, value: value)), do: {to_string(name), to_string(value)}

  defp text?(node), do: Record.is_record(node, :xmlText)
  defp element?(node), do: Record.is_record(node, :xmlElement)

  defp text(xml_text(value: value)), do: IO.chardata_to_string(value)
end
