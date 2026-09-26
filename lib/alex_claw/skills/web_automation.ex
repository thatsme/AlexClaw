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
  alias AlexClaw.WebAutomation.{PlayLock, Recipe, Recording}

  @default_deadline_ms 120_000
  # How much longer than the play's own deadline AlexClaw waits for the answer.
  @answer_margin_ms 5_000

  @typedoc "Why a request to the sidecar was not made or did not succeed."
  @type request_error ::
          :web_automator_disabled
          | :web_automator_token_missing
          | :busy
          | {:invalid_recipe, term()}
          | {:http, pos_integer(), term()}
          | Exception.t()

  @typedoc "Why a play did not complete."
  @type play_error ::
          request_error()
          | :timeout
          | :stopped
          | {:automation_failed, String.t() | nil, map()}
          | {:unexpected_response, term()}
          | {:login_required, [String.t()]}
          | {:not_bound, String.t()}
          | {:login_unavailable, String.t(), term()}

  @impl true
  @spec description() :: String.t()
  def description, do: "Browser automation — record interactions and replay headlessly"

  @impl true
  @spec routes() :: [atom()]
  # A failed play, a timeout included ({:error, :timeout}), takes :on_error.
  def routes, do: [:on_success, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint,
    do: ~s|{"action": "play"} — runs the automation config from the assigned Resource|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"action" => "play"}

  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema do
    %{
      "action" => %{type: :string, required: false},
      "url" => %{type: :string, required: false},
      "steps" => %{type: :list, required: false},
      "extra_steps" => %{type: :list, required: false},
      "timeout_ms" => %{type: :integer, required: false},
      "patterns" => %{type: :list, required: false},
      "timeout" => %{type: :integer, required: false}
    }
  end

  @impl true
  @spec available?() :: boolean()
  def available?, do: Config.enabled?("web_automator.enabled")

  # Recording is authoring, done in the admin UI (Resources page), never by a
  # workflow step (0.4.0 S5c). Checked at save, and at run time for a step
  # saved before.
  @impl true
  @spec validate_config(map()) :: :ok | {:error, [String.t()]}
  def validate_config(%{"action" => "record"}),
    do:
      {:error,
       [
         "action record: recording is authoring — done in the admin UI (Resources page), not by a workflow step"
       ]}

  def validate_config(_config), do: :ok

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{"Play" => %{"action" => "play"}}
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "action: play (default) or record. play runs the recipe from the assigned Resource (type: automation), " <>
        "or the config's own url and steps; extra_steps are appended to the resource's steps. " <>
        "timeout_ms bounds the whole play (default 120000, at most 600000); one play runs at a time."

  @impl true
  @spec run(map()) ::
          {:ok, String.t(), :on_success} | {:error, play_error() | :no_url}
  def run(args) do
    config = args[:config] || %{}
    resources = args[:resources] || []

    case config["action"] do
      "record" -> record(config)
      _ -> play(Map.delete(config, "timeout_ms"), resources, deadline_opts(config))
    end
  end

  # A workflow step's timeout_ms is the play's deadline; it is not part of the recipe.
  defp deadline_opts(%{"timeout_ms" => ms}) when is_integer(ms), do: [deadline_ms: ms]
  defp deadline_opts(_config), do: []

  @doc "Start a recording session. Returns noVNC URL for interaction."
  @spec record(map()) ::
          {:ok, String.t(), :on_success}
          | {:error, request_error() | :no_url | {:unexpected_response, term()}}
  def record(config) do
    url = config["url"] || ""

    if url == "" do
      {:error, :no_url}
    else
      patterns = config["patterns"] || []
      timeout = config["timeout"] || 300

      body = %{url: url, patterns: patterns, timeout: timeout}

      "/record"
      |> post(body)
      |> recording_started()
    end
  end

  defp recording_started({:ok, %{"session_id" => sid, "novnc_url" => novnc}}),
    do: {:ok, "Recording started!\nSession: `#{sid}`\nBrowser: #{novnc}", :on_success}

  defp recording_started({:ok, other}), do: {:error, {:unexpected_response, other}}
  defp recording_started({:error, reason}), do: {:error, reason}

  @doc "Stop an active recording session."
  @spec stop_recording(String.t()) :: {:ok, map()} | {:error, request_error()}
  def stop_recording(session_id) do
    post("/record/#{session_id}/stop", %{})
  end

  # A web_automation step's own config keys; the rest of the config is the recipe.
  @skill_keys ~w(action resource extra_steps)

  @doc """
  Play a recipe headlessly.

  A recipe with a login still to attach is refused before anything is sent:
  `{:error, {:login_required, selectors}}`. Its logins are resolved for the
  recipe's origin (`AlexClaw.WebAutomation.Recording.resolved/1`); a login
  bound elsewhere is `{:error, {:not_bound, selector}}`. The resolved recipe is
  validated against the contract (`AlexClaw.WebAutomation.Recipe`) before it is
  sent: an invalid one is `{:error, {:invalid_recipe, reasons}}`.
  `opts[:deadline_ms]` bounds the whole play (default 120_000); past it the result
  is `{:error, :timeout}`. One play runs at a time: while one runs, another is
  `{:error, :busy}` without a request. A run that fails keeps its partial
  results: `{:error, {:automation_failed, error, partial}}`. See `play_error()`.
  """
  @spec play(map(), list(), keyword()) :: {:ok, String.t(), :on_success} | {:error, play_error()}
  def play(config, resources, opts \\ []) do
    deadline_ms = Keyword.get(opts, :deadline_ms, @default_deadline_ms)

    with {:ok, recipe} <- recipe(config, resources) do
      PlayLock.run(fn -> send_play(recipe, deadline_ms) end)
    end
  end

  # AlexClaw waits deadline + margin; past it, it asks the sidecar to stop the
  # play, behind the sidecar's own deadline.
  defp send_play(recipe, deadline_ms) do
    play_id = new_play_id()
    body = %{play_id: play_id, deadline_ms: deadline_ms, config: recipe}

    :post
    |> request("/play", json: body, receive_timeout: deadline_ms + @answer_margin_ms)
    |> gave_up(play_id)
    |> played_result(recipe)
  end

  defp new_play_id, do: "p-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp gave_up({:error, %Req.TransportError{reason: :timeout}}, play_id) do
    request(:post, "/play/#{play_id}/stop", json: %{}, receive_timeout: 5_000, retry: false)
    {:error, :timeout}
  end

  defp gave_up(result, _play_id), do: result

  defp recipe(config, resources) do
    assembled = config |> find_automation_config(resources) |> Map.drop(@skill_keys)

    with {:ok, resolved} <- Recording.resolved(assembled),
         do: resolved |> Recipe.validate() |> invalid_as_reason()
  end

  defp invalid_as_reason({:error, reasons}), do: {:error, {:invalid_recipe, reasons}}
  defp invalid_as_reason(ok), do: ok

  defp played_result({:ok, %{"status" => "success"} = result}, recipe), do: played(result, recipe)

  defp played_result({:ok, %{"status" => "error"} = result}, _recipe),
    do:
      {:error,
       {:automation_failed, result["error"],
        Map.take(result, ~w(downloads screenshots scraped_data))}}

  defp played_result({:ok, %{"status" => "timeout"}}, _recipe), do: {:error, :timeout}
  defp played_result({:ok, %{"status" => "stopped"}}, _recipe), do: {:error, :stopped}
  defp played_result({:ok, other}, _recipe), do: {:error, {:unexpected_response, other}}
  defp played_result({:error, reason}, _recipe), do: {:error, reason}

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

  @doc "Get sidecar status. Short timeout, no retry: the Services page waits on it."
  @spec status() :: {:ok, map()} | {:error, request_error()}
  def status, do: request(:get, "/status", receive_timeout: 5_000, retry: false)

  @doc "Force stop any running session."
  @spec force_stop() :: {:ok, map()} | {:error, request_error()}
  def force_stop, do: post("/stop", %{})

  # --- Helpers ---

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

  defp post(path, body), do: request(:post, path, json: body, receive_timeout: 300_000)

  # The one place a request to the sidecar is made: "disabled" means nothing is
  # sent, and nothing is sent without the token.
  defp request(method, path, opts) do
    with :ok <- ensure_enabled(),
         {:ok, token} <- fetch_token() do
      [method: method, url: base_url() <> path, auth: {:bearer, token}]
      |> Keyword.merge(opts)
      |> Req.request()
      |> handle_response(method, path)
    end
  end

  defp ensure_enabled do
    if Config.enabled?("web_automator.enabled"), do: :ok, else: {:error, :web_automator_disabled}
  end

  # From the token file (WEB_AUTOMATOR_TOKEN_FILE, read by config/runtime.exs),
  # not a setting: it stays out of the database and its exports.
  defp fetch_token do
    case Application.get_env(:alex_claw, :web_automator_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :web_automator_token_missing}
    end
  end

  defp handle_response({:ok, %{status: status, body: body}}, _method, _path)
       when status in 200..299,
       do: {:ok, body}

  defp handle_response({:ok, %{status: 409}}, _method, _path), do: {:error, :busy}

  defp handle_response({:ok, %{status: 422, body: body}}, _method, _path),
    do: {:error, {:invalid_recipe, detail(body)}}

  defp handle_response({:ok, %{status: status, body: body}}, method, path) do
    Logger.warning("WebAutomation #{method} #{path} failed: #{status}", skill: :web_automation)
    {:error, {:http, status, body}}
  end

  defp handle_response({:error, reason}, method, path) do
    Logger.error("WebAutomation #{method} #{path} error: #{inspect(reason)}",
      skill: :web_automation
    )

    {:error, reason}
  end

  defp detail(%{"detail" => detail}), do: detail
  defp detail(body), do: body
end
