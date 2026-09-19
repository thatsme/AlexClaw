defmodule AlexClaw.Skills.WebAutomation do
  @moduledoc """
  Web automation skill — drives the web-automator sidecar for browser
  recording and headless replay of website interactions.
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec external() :: boolean()
  def external, do: true
  require Logger

  alias AlexClaw.Config

  @impl true
  @spec description() :: String.t()
  def description, do: "Browser automation — record interactions and replay headlessly"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_success, :on_timeout, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint,
    do: ~s|{"action": "play"} — runs the automation config from the assigned Resource|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"action" => "play", "resource" => "automation resource name"}

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "Play" => %{"action" => "play"},
      "Record" => %{"action" => "record", "url" => "https://..."}
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "action: play (run automation), record (start recording), status (check sidecar). The automation config comes from the assigned Resource (type: automation)."

  @impl true
  @spec run(map()) :: {:ok, String.t(), atom()} | {:error, any()}
  def run(args) do
    if enabled?() do
      config = args[:config] || %{}
      resources = args[:resources] || []

      case config["action"] do
        "record" -> record(config)
        "play" -> play(config, resources)
        _ -> play(config, resources)
      end
    else
      {:error, :web_automator_disabled}
    end
  end

  @doc "Start a recording session. Returns noVNC URL for interaction."
  @spec record(map()) :: {:ok, String.t(), atom()} | {:error, any()}
  def record(config) do
    url = config["url"] || ""

    if url == "" do
      {:error, :no_url}
    else
      patterns = config["patterns"] || []
      timeout = config["timeout"] || 300

      body = %{url: url, patterns: patterns, timeout: timeout}

      case post("/record", body) do
        {:ok, %{"session_id" => sid, "novnc_url" => novnc}} ->
          {:ok, "Recording started!\nSession: `#{sid}`\nBrowser: #{novnc}", :on_success}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Stop an active recording session."
  @spec stop_recording(String.t()) :: {:ok, any()} | {:error, any()}
  def stop_recording(session_id) do
    post("/record/#{session_id}/stop", %{})
  end

  @doc "Play an automation config headlessly."
  @spec play(map(), list()) :: {:ok, String.t(), atom()} | {:error, any()}
  def play(config, resources) do
    automation_config = find_automation_config(config, resources)

    case post("/play", %{config: automation_config}) do
      {:ok, %{"status" => "success"} = result} -> played(result, automation_config)
      {:ok, %{"status" => "error", "error" => error}} -> {:error, {:automation_failed, error}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp played(result, automation_config) do
    downloads = result["downloads"] || []
    scraped = result["scraped_data"] || []

    summary =
      ["Automation complete (#{length(automation_config["steps"] || [])} steps)."] ++
        count_note(downloads, "file(s) downloaded.") ++
        count_note(scraped, "data set(s) scraped.")

    {:ok, Enum.join(summary, "\n") <> scraped_preview(scraped), :on_success}
  end

  defp count_note([], _label), do: []
  defp count_note(items, label), do: ["#{length(items)} #{label}"]

  defp scraped_preview([]), do: ""

  defp scraped_preview(scraped) do
    preview =
      scraped
      |> Enum.take(2)
      |> Enum.map_join("\n\n", &preview_entry/1)

    "\n\n" <> preview
  end

  defp preview_entry(%{"type" => "text", "data" => text}) when is_binary(text),
    do: String.slice(text, 0, 3000)

  defp preview_entry(%{"type" => type, "rows" => rows, "headers" => headers}),
    do: "#{type}: #{length(headers)} cols, #{length(rows)} rows"

  defp preview_entry(other), do: String.slice(inspect(other), 0, 500)

  @doc "Get sidecar status."
  @spec status() :: {:ok, any()} | {:error, any()}
  def status, do: get("/status")

  @doc "Force stop any running session."
  @spec force_stop() :: {:ok, any()} | {:error, any()}
  def force_stop, do: post("/stop", %{})

  # --- Helpers ---

  defp enabled? do
    Config.enabled?("web_automator.enabled")
  end

  defp base_url do
    Config.get("web_automator.host") || "http://web-automator:6900"
  end

  defp find_automation_config(config, resources) do
    extra_steps = config["extra_steps"] || []

    base =
      if config["steps"] || config["url"] do
        config
      else
        case Enum.find(resources, &(&1.type == "automation")) do
          nil -> config
          resource -> build_config_from_resource(resource)
        end
      end

    if extra_steps != [] do
      existing = base["steps"] || []
      Map.put(base, "steps", existing ++ extra_steps)
    else
      base
    end
  end

  defp build_config_from_resource(resource) do
    base = %{"url" => resource.url}

    case resource.metadata do
      metadata when is_map(metadata) -> Map.merge(base, metadata)
      _ -> base
    end
  end

  defp get(path) do
    url = base_url() <> path

    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("WebAutomation GET #{path} failed: #{status}",
          skill: :web_automation
        )

        {:error, {:http, status, body}}

      {:error, reason} ->
        Logger.error("WebAutomation GET #{path} error: #{inspect(reason)}",
          skill: :web_automation
        )

        {:error, reason}
    end
  end

  defp post(path, body) do
    url = base_url() <> path

    case Req.post(url, json: body, receive_timeout: 300_000) do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        {:ok, resp}

      {:ok, %{status: status, body: resp}} ->
        Logger.warning("WebAutomation POST #{path} failed: #{status}",
          skill: :web_automation
        )

        {:error, {:http, status, resp}}

      {:error, reason} ->
        Logger.error("WebAutomation POST #{path} error: #{inspect(reason)}",
          skill: :web_automation
        )

        {:error, reason}
    end
  end
end
