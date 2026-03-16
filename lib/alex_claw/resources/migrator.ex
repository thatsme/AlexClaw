defmodule AlexClaw.Resources.Migrator do
  @moduledoc """
  One-time migration of RSS feeds from the Config (settings table) to the resources table.
  """
  require Logger

  alias AlexClaw.Resources

  def migrate_feeds do
    case AlexClaw.Config.get("rss_feeds") do
      feeds when is_list(feeds) and feeds != [] ->
        Logger.info("Migrating #{length(feeds)} RSS feeds from config to resources table")

        Enum.each(feeds, fn feed ->
          name = feed["name"] || feed[:name]
          url = feed["url"] || feed[:url]
          enabled = feed["enabled"] || feed[:enabled] || true

          case Resources.create_resource(%{
                 name: name,
                 type: "rss_feed",
                 url: url,
                 enabled: enabled
               }) do
            {:ok, _resource} ->
              Logger.info("Migrated feed: #{name}")

            {:error, changeset} ->
              Logger.warning("Failed to migrate feed '#{name}': #{inspect(changeset.errors)}")
          end
        end)

        AlexClaw.Config.delete("rss_feeds")
        Logger.info("Feed migration complete, removed rss_feeds config key")

      _ ->
        Logger.debug("No RSS feeds to migrate from config")
    end
  end
end
