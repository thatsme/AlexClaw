defmodule AlexClaw.Skills.GoogleCalendar do
  @moduledoc """
  Google Calendar skill. Fetches upcoming events using OAuth2.

  Requires config keys (set via Admin > Config or .env):
  - google.oauth.client_id
  - google.oauth.client_secret
  - google.oauth.refresh_token

  To obtain a refresh token, see INSTALLATION.md > Google Calendar Setup.

  Configurable via step config:
  - "calendar_id" — which calendar to query (default: "primary")
  - "days" — how many days ahead to look (default: 1)
  - "max_results" — max events to return (default: 20)
  """
  @behaviour AlexClaw.Skill
  @impl true
  def external, do: true
  @impl true
  @spec description() :: String.t()
  def description, do: "Fetches upcoming events from Google Calendar"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_events, :on_empty, :on_error]

  @impl true
  def step_fields, do: [:config]

  @impl true
  def config_hint, do: ~s|{"action": "list", "days": 1} or {"action": "create", "title": "Meeting", "date": "2026-03-20", "time": "14:00"}|

  @impl true
  def config_scaffold, do: %{"action" => "list", "calendar_id" => "primary", "days" => 1, "max_results" => 20}

  @impl true
  def config_presets do
    %{
      "List events" => %{"action" => "list", "calendar_id" => "primary", "days" => 1, "max_results" => 20},
      "Create event" => %{"action" => "create", "title" => "Meeting", "date" => "2026-03-20", "time" => "14:00", "duration" => 60}
    }
  end

  @impl true
  def config_help, do: "action: list (fetch events) or create (new event with title, date, time). calendar_id: which calendar (default: primary). days: how many days ahead. max_results: event limit."

  require Logger
  import AlexClaw.Skills.Helpers, only: [parse_int: 2]

  @calendar_api "https://www.googleapis.com/calendar/v3"

  @impl true
  @spec run(map()) :: {:ok, String.t()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    calendar_id = config["calendar_id"] || "primary"
    days = parse_int(config["days"], 1)
    max_results = parse_int(config["max_results"], 20)

    case AlexClaw.Google.TokenManager.get_token() do
      {:ok, token} ->
        fetch_events(token, calendar_id, days, max_results)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_events(token, calendar_id, days, max_results) do
    now = DateTime.utc_now()
    time_min = DateTime.to_iso8601(now)
    time_max = DateTime.to_iso8601(DateTime.add(now, days * 86400))

    url = "#{@calendar_api}/calendars/#{URI.encode(calendar_id)}/events"

    params = [
      timeMin: time_min,
      timeMax: time_max,
      maxResults: max_results,
      singleEvents: true,
      orderBy: "startTime"
    ]

    headers = [{"authorization", "Bearer #{token}"}]

    case Req.get(url, params: params, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"items" => events}}} when events != [] ->
        formatted = format_events(events)
        Logger.info("GoogleCalendar: fetched #{length(events)} events", skill: :google_calendar)
        {:ok, formatted, :on_events}

      {:ok, %{status: 200, body: _}} ->
        {:ok, "No upcoming events.", :on_empty}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Google Calendar API error: #{status}", skill: :google_calendar)
        {:error, {:calendar_api, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_events([]), do: "No upcoming events."

  defp format_events(events) do
    events
    |> Enum.map(&format_event/1)
    |> Enum.join("\n")
  end

  defp format_event(event) do
    summary = event["summary"] || "(No title)"
    location = event["location"]
    start_time = parse_event_time(event["start"])
    end_time = parse_event_time(event["end"])

    line = "#{start_time} - #{end_time}: #{summary}"
    if location, do: "#{line} (#{location})", else: line
  end

  defp parse_event_time(%{"dateTime" => dt}) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _offset} ->
        Calendar.strftime(datetime, "%b %d %H:%M")

      _ ->
        dt
    end
  end

  defp parse_event_time(%{"date" => date}), do: "#{date} (all day)"
  defp parse_event_time(_), do: "?"

end
