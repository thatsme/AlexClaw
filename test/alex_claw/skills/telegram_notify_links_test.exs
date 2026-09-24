defmodule AlexClaw.Skills.TelegramNotifyLinksTest do
  @moduledoc """
  telegram_notify renders links as links, safely (reports/DIGEST_LINKS_FACTS.md;
  0.3.52).

  It converted the model's Markdown to Telegram HTML after escaping &, < and
  >, and did not convert Markdown links: `[title](url)` arrived as literal
  text. Only bare URLs were clickable, because Telegram links them itself —
  and it then added a preview card for the first one.

  Now, in `TelegramNotify.to_html/1` (the pure conversion the skill sends):
  - `[text](https://…)` becomes `<a href="https://…">text</a>`, with the text
    escaped and the URL's quotes and angle brackets escaped;
  - only http and https are linked; any other scheme stays literal text;
  - everything else is escaped as before.
  And `link_preview: false` in the step config turns the preview card off.
  The `parse_mode` option was advertised and never read; it is no longer
  advertised.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias AlexClaw.Skills.TelegramNotify

  describe "to_html/1" do
    test "a Markdown link becomes an anchor" do
      assert TelegramNotify.to_html("• Alpha [source](https://a.example/1)") =~
               ~s(<a href="https://a.example/1">source</a>)
    end

    test "the link text is escaped" do
      html = TelegramNotify.to_html("[<b>x</b> & y](https://a.example/1)")
      assert html =~ ~s(<a href="https://a.example/1">&lt;b&gt;x&lt;/b&gt; &amp; y</a>)
    end

    test "a URL cannot break out of the attribute" do
      html = TelegramNotify.to_html(~s{[x](https://a.example/"><script>1</script>)})
      refute html =~ "<script>"
      refute html =~ ~s(href="https://a.example/">)
    end

    for scheme <- ["javascript:alert(1)", "data:text/html,x", "tg://resolve?domain=x", "ftp://x"] do
      test "#{scheme} is not linked" do
        html = TelegramNotify.to_html("[click](#{unquote(scheme)})")
        refute html =~ "<a "
      end
    end

    test "text around links is escaped as before" do
      assert TelegramNotify.to_html("a < b & c") == "a &lt; b &amp; c"
    end
  end

  describe "the step's options" do
    test "link_preview: false turns the preview card off" do
      assert %{link_preview_options: %{is_disabled: true}} =
               TelegramNotify.send_options(%{"link_preview" => false})
    end

    test "previews stay as Telegram's default otherwise" do
      refute Map.has_key?(TelegramNotify.send_options(%{}), :link_preview_options)
    end

    test "parse_mode is no longer advertised" do
      refute TelegramNotify.config_help() =~ "parse_mode"
      refute inspect(TelegramNotify.config_scaffold()) =~ "parse_mode"
    end
  end
end
