defmodule AlexClaw.Skills.RSSXXETest do
  use ExUnit.Case, async: true

  alias AlexClaw.Skills.RSSCollector

  @secret_path "/tmp/rss_xxe_secret"

  setup do
    File.write!(@secret_path, "TOP_SECRET_VALUE")
    on_exit(fn -> File.rm_rf!(@secret_path) end)
    :ok
  end

  defp feed(title) do
    """
    <rss><channel>
      <item><title>#{title}</title><link>http://example.com/1</link>
      <description>d</description><pubDate>Mon, 01 Jan 2026 00:00:00 GMT</pubDate></item>
    </channel></rss>
    """
  end

  # These pin behaviour rather than fixing a hole: the xmerl in the current OTP
  # refuses entity declarations regardless of the :dtd option. If a future OTP or
  # sweet_xml starts expanding them, these fail here instead of in production.
  describe "untrusted feed bodies" do
    test "an external entity is not expanded into the parsed item" do
      body = """
      <?xml version="1.0"?>
      <!DOCTYPE rss [<!ENTITY xxe SYSTEM "file://#{@secret_path}">]>
      #{feed("&xxe;")}
      """

      items = RSSCollector.parse_rss("probe", body)

      refute inspect(items) =~ "TOP_SECRET_VALUE",
             "external entity was expanded: #{inspect(items)}"
    end

    test "an internal entity is not expanded either" do
      body = """
      <?xml version="1.0"?>
      <!DOCTYPE rss [<!ENTITY inner "EXPANDED_INTERNAL">]>
      #{feed("&inner;")}
      """

      items = RSSCollector.parse_rss("probe", body)

      refute inspect(items) =~ "EXPANDED_INTERNAL",
             "internal entity was expanded: #{inspect(items)}"
    end

    test "a nested-entity feed does not exhaust the parser" do
      body = """
      <?xml version="1.0"?>
      <!DOCTYPE lolz [
        <!ENTITY lol "lol">
        <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
        <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
        <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
        <!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;">
      ]>
      #{feed("&lol5;")}
      """

      items = RSSCollector.parse_rss("probe", body)

      # Either refused outright or returned unexpanded; never 100k characters.
      assert is_list(items)
      refute inspect(items) =~ String.duplicate("lol", 50)
    end
  end

  describe "ordinary feeds still parse" do
    test "a feed with no DTD yields its items" do
      items = RSSCollector.parse_rss("probe", feed("Ordinary headline"))

      assert [%{title: "Ordinary headline", feed: "probe"}] = items
    end

    test "malformed XML yields no items rather than raising" do
      assert [] = RSSCollector.parse_rss("probe", "<rss><channel><item>")
    end
  end
end
