defmodule AlexClawWeb.TimeHelpers do
  @moduledoc "Converts UTC datetimes to the user's configured display timezone."

  alias AlexClaw.Config

  @doc "Format a UTC datetime to the configured timezone with date and time."
  def format_datetime(nil), do: ""

  def format_datetime(%DateTime{} = dt) do
    tz = display_timezone()

    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M:%S")
      {:error, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
    end
  end

  def format_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_datetime()
  end

  defp display_timezone do
    case Config.get("display.timezone") do
      tz when is_binary(tz) and tz != "" -> tz
      _ -> "Etc/UTC"
    end
  end
end
