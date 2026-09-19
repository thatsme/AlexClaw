defmodule AlexClaw.Resources.Migrator do
  @moduledoc """
  One-time migration of RSS feeds from the Config (settings table) to the resources table.
  """
  require Logger

  alias AlexClaw.Resources

  @spec migrate_feeds() :: :ok
  def migrate_feeds do
    case AlexClaw.Config.get("rss_feeds") do
      feeds when is_list(feeds) and feeds != [] -> migrate(feeds)
      _ -> Logger.debug("No RSS feeds to migrate from config")
    end
  end

  defp migrate(feeds) do
    Logger.info("Migrating #{length(feeds)} RSS feeds from config to resources table")
    Enum.each(feeds, &migrate_feed/1)
    AlexClaw.Config.delete("rss_feeds")
    Logger.info("Feed migration complete, removed rss_feeds config key")
  end

  defp migrate_feed(feed) do
    name = feed["name"] || feed[:name]

    %{
      name: name,
      type: "rss_feed",
      url: feed["url"] || feed[:url],
      enabled: feed["enabled"] || feed[:enabled] || true
    }
    |> Resources.create_resource()
    |> migrated(name)
  end

  defp migrated({:ok, _resource}, name), do: Logger.info("Migrated feed: #{name}")

  defp migrated({:error, changeset}, name),
    do: Logger.warning("Failed to migrate feed '#{name}': #{inspect(changeset.errors)}")
end
