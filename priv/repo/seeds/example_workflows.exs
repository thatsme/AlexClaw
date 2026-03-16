# Example Workflows Seed
# Run with: mix run priv/repo/seeds/example_workflows.exs
# Or automatically on first boot via entrypoint.sh
#
# Creates:
# - General-purpose RSS feeds (tech, news, security)
# - "Tech News Digest" workflow
# - "Web Research" workflow
#
# All feeds can be managed via Admin > Feeds after setup.

alias AlexClaw.{Resources, Workflows}

IO.puts("=== Seeding Example Resources & Workflows ===\n")

# --- RSS Feeds ---

feeds = [
  %{
    name: "Hacker News",
    type: "rss_feed",
    url: "https://hnrss.org/frontpage",
    tags: ["tech", "programming"],
    enabled: true
  },
  %{
    name: "Elixir Forum",
    type: "rss_feed",
    url: "https://elixirforum.com/latest.rss",
    tags: ["tech", "elixir", "beam"],
    enabled: true
  },
  %{
    name: "Ars Technica",
    type: "rss_feed",
    url: "http://feeds.arstechnica.com/arstechnica/index",
    tags: ["tech", "science"],
    enabled: true
  },
  %{
    name: "BBC News",
    type: "rss_feed",
    url: "http://feeds.bbci.co.uk/news/rss.xml",
    tags: ["news", "world"],
    enabled: true
  },
  %{
    name: "Reuters",
    type: "rss_feed",
    url: "https://www.reutersagency.com/feed/?best-topics=tech",
    tags: ["news", "tech"],
    enabled: true
  },
  %{
    name: "Krebs on Security",
    type: "rss_feed",
    url: "https://krebsonsecurity.com/feed/",
    tags: ["security", "cybersecurity"],
    enabled: true
  }
]

feed_resources =
  Enum.map(feeds, fn feed ->
    case Resources.create_resource(feed) do
      {:ok, resource} ->
        IO.puts("  + Created feed: #{resource.name}")
        resource

      {:error, changeset} ->
        IO.puts("  ! Feed '#{feed.name}' failed: #{inspect(changeset.errors)}")
        nil
    end
  end)
  |> Enum.reject(&is_nil/1)

IO.puts("\nCreated #{length(feed_resources)} RSS feeds\n")

# --- Workflow 1: Tech News Digest ---

IO.puts("--- Creating 'Tech News Digest' workflow ---")

{:ok, news_wf} =
  Workflows.create_workflow(%{
    name: "Tech News Digest",
    description:
      "Collects news from RSS feeds, filters by relevance, and delivers a summary digest via Telegram.",
    enabled: true,
    schedule: nil,
    metadata: %{}
  })

{:ok, _} =
  Workflows.add_step(news_wf, %{
    name: "Collect News",
    skill: "rss_collector",
    position: 1,
    config: %{"threshold" => 0.3, "force" => false},
    llm_tier: "light"
  })

{:ok, _} =
  Workflows.add_step(news_wf, %{
    name: "Summarize",
    skill: "llm_transform",
    position: 2,
    prompt_template: """
    Summarize the following news items into a concise digest.
    Group by topic (tech, security, world news).
    For each item: one-line summary with the key takeaway.
    Keep it under 2000 characters.

    News items:
    {input}
    """,
    llm_tier: "medium"
  })

{:ok, _} =
  Workflows.add_step(news_wf, %{
    name: "Deliver to Telegram",
    skill: "telegram_notify",
    position: 3,
    config: %{}
  })

IO.puts("  + Created workflow: #{news_wf.name} (3 steps)")

# Assign feeds to the news digest workflow
Enum.each(feed_resources, fn resource ->
  case Workflows.assign_resource(news_wf, resource.id, "input") do
    {:ok, _} -> IO.puts("  + Assigned feed: #{resource.name}")
    {:error, err} -> IO.puts("  ! Failed to assign #{resource.name}: #{inspect(err)}")
  end
end)

# --- Workflow 2: Web Research ---

IO.puts("\n--- Creating 'Web Research' workflow ---")

{:ok, research_wf} =
  Workflows.create_workflow(%{
    name: "Web Research",
    description:
      "Searches the web for a topic, synthesizes findings into a research brief, and delivers via Telegram. Edit step 1 config to set your query.",
    enabled: true,
    schedule: nil,
    metadata: %{}
  })

{:ok, _} =
  Workflows.add_step(research_wf, %{
    name: "Search",
    skill: "web_search",
    position: 1,
    config: %{"query" => "latest developments in Elixir and BEAM ecosystem"},
    llm_tier: "light"
  })

{:ok, _} =
  Workflows.add_step(research_wf, %{
    name: "Synthesize",
    skill: "llm_transform",
    position: 2,
    prompt_template: """
    Based on the following search results, write a concise research brief.
    Include: key findings, notable developments, and sources.
    Keep it factual and under 2000 characters.

    Search results:
    {input}
    """,
    llm_tier: "medium"
  })

{:ok, _} =
  Workflows.add_step(research_wf, %{
    name: "Deliver to Telegram",
    skill: "telegram_notify",
    position: 3,
    config: %{}
  })

IO.puts("  + Created workflow: #{research_wf.name} (3 steps)")

# --- Financial RSS Feeds ---

IO.puts("\n--- Creating financial RSS feeds ---")

financial_feeds = [
  %{
    name: "Bloomberg Markets",
    type: "rss_feed",
    url: "https://feeds.bloomberg.com/markets/news.rss",
    tags: ["finance", "markets"],
    enabled: true
  },
  %{
    name: "Yahoo Finance",
    type: "rss_feed",
    url: "https://finance.yahoo.com/news/rssindex",
    tags: ["finance", "markets"],
    enabled: true
  },
  %{
    name: "CNBC Economy",
    type: "rss_feed",
    url: "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=20910258",
    tags: ["finance", "economy"],
    enabled: true
  },
  %{
    name: "MarketWatch",
    type: "rss_feed",
    url: "http://feeds.marketwatch.com/marketwatch/topstories/",
    tags: ["finance", "markets"],
    enabled: true
  }
]

fin_feed_resources =
  Enum.map(financial_feeds, fn feed ->
    case Resources.create_resource(feed) do
      {:ok, resource} ->
        IO.puts("  + Created feed: #{resource.name}")
        resource

      {:error, changeset} ->
        IO.puts("  ! Feed '#{feed.name}' failed: #{inspect(changeset.errors)}")
        nil
    end
  end)
  |> Enum.reject(&is_nil/1)

# --- Workflow 3: Financial Markets Recap ---

IO.puts("\n--- Creating 'Financial Markets Recap' workflow ---")

{:ok, fin_wf} =
  Workflows.create_workflow(%{
    name: "Financial Markets Recap",
    description:
      "Collects financial news from RSS feeds, analyzes market sentiment, and delivers a daily recap via Telegram.",
    enabled: true,
    schedule: nil,
    metadata: %{}
  })

{:ok, _} =
  Workflows.add_step(fin_wf, %{
    name: "Collect Financial News",
    skill: "rss_collector",
    position: 1,
    config: %{"threshold" => 0.3, "force" => false},
    llm_tier: "light"
  })

{:ok, _} =
  Workflows.add_step(fin_wf, %{
    name: "Market Recap",
    skill: "llm_transform",
    position: 2,
    prompt_template: """
    You are a financial analyst. Summarize the following market news into a concise daily recap.

    Structure:
    1. **Market Movers** — key events driving markets today
    2. **Sector Highlights** — notable sector-specific developments
    3. **Macro & Economy** — central bank, policy, economic data
    4. **Outlook** — brief forward-looking sentiment

    Keep it actionable and under 2000 characters.

    News items:
    {input}
    """,
    llm_tier: "medium"
  })

{:ok, _} =
  Workflows.add_step(fin_wf, %{
    name: "Deliver to Telegram",
    skill: "telegram_notify",
    position: 3,
    config: %{}
  })

IO.puts("  + Created workflow: #{fin_wf.name} (3 steps)")

# Assign financial feeds to workflow
Enum.each(fin_feed_resources, fn resource ->
  case Workflows.assign_resource(fin_wf, resource.id, "input") do
    {:ok, _} -> IO.puts("  + Assigned feed: #{resource.name}")
    {:error, err} -> IO.puts("  ! Failed to assign #{resource.name}: #{inspect(err)}")
  end
end)

IO.puts("""

=== Done! ===

Next steps:
  1. Open Admin > Workflows to review the example workflows
  2. Click "Run Now" to test each workflow
  3. Set a schedule (e.g. "0 8 * * *" for daily 8am) via Admin > Workflows
  4. Manage RSS feeds via Admin > Feeds
  5. Create your own workflows from the Admin UI
""")
