defmodule AlexClaw.WebAutomation.Recipe do
  @moduledoc """
  The recipe contract: what the web-automator sidecar's `/play` accepts.

  A recipe is exactly `%{"url" => url, "steps" => steps}`. `url` is http(s) with
  a host. Every step names one action and carries only that action's fields,
  plus an optional `timeout_ms` (an integer, 1..120000); unknown keys anywhere
  are refused. A fill that types a login carries the `origin` the login is
  bound to (`scheme://host[:port]`); the sidecar types it only on a page of
  that origin. The sidecar enforces the same contract (`app.recipe`), and both
  are tested against `web-automator/tests/contract/recipes.json`.
  """

  @max_timeout_ms 120_000
  @max_wait_seconds 60
  @screenshot_name ~r/\A[a-z0-9_-]{1,40}\z/

  # action => {required fields, optional fields}; each field => its type.
  @actions %{
    "navigate" => {%{"url" => :url}, %{}},
    "click" => {%{"selector" => :selector}, %{}},
    "fill" =>
      {%{"selector" => :selector, "value" => :string},
       %{"input_type" => :date_type, "origin" => :origin}},
    "select" => {%{"selector" => :selector, "value" => :string}, %{}},
    "check" => {%{"selector" => :selector, "checked" => :boolean}, %{}},
    "wait" => {%{"seconds" => :wait_seconds}, %{}},
    "keyboard" => {%{"key" => :selector}, %{}},
    "download" => {%{"selector" => :selector}, %{}},
    "scrape" => {%{}, %{"selector" => :selector}},
    "scrape_text" => {%{}, %{"selector" => :selector}},
    "extract_grid" => {%{"selector" => :selector}, %{}},
    "screenshot" => {%{}, %{"name" => :screenshot_name, "full_page" => :boolean}}
  }

  @doc "The actions a recipe step may name."
  @spec actions() :: [String.t()]
  def actions, do: Map.keys(@actions)

  @doc """
  `{:ok, recipe}` if `recipe` is valid under the contract, otherwise
  `{:error, reasons}` with one message per problem found.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(recipe) do
    case recipe_errors(recipe) do
      [] -> {:ok, recipe}
      errors -> {:error, errors}
    end
  end

  defp recipe_errors(%{} = recipe) do
    unknown_keys(recipe, ~w(url steps), "recipe") ++
      required(recipe, "url", :url, "recipe") ++ steps_errors(Map.fetch(recipe, "steps"))
  end

  defp recipe_errors(_), do: ["a recipe is an object"]

  defp steps_errors(:error), do: ["recipe: steps is required"]

  defp steps_errors({:ok, steps}) when is_list(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {step, i} -> step_errors(step, "step #{i}") end)
  end

  defp steps_errors({:ok, _}), do: ["recipe: steps is a list"]

  defp step_errors(%{"action" => action} = step, at) when is_map_key(@actions, action) do
    {required, optional} = Map.fetch!(@actions, action)
    allowed = Map.keys(required) ++ Map.keys(optional) ++ ["action", "timeout_ms"]

    unknown_keys(step, allowed, at) ++
      Enum.flat_map(required, fn {field, type} -> required(step, field, type, at) end) ++
      Enum.flat_map(optional, fn {field, type} -> optional(step, field, type, at) end) ++
      optional(step, "timeout_ms", :timeout_ms, at)
  end

  defp step_errors(%{"action" => action}, at) when is_binary(action),
    do: ["#{at}: unknown action #{inspect(action)}"]

  defp step_errors(%{"action" => _}, at), do: ["#{at}: action is a string"]
  defp step_errors(%{}, at), do: ["#{at}: action is required"]
  defp step_errors(_, at), do: ["#{at}: a step is an object"]

  defp unknown_keys(map, allowed, at) do
    for key <- Map.keys(map), key not in allowed, do: "#{at}: unknown field #{inspect(key)}"
  end

  defp required(map, field, type, at) do
    case Map.fetch(map, field) do
      {:ok, value} -> type_errors(value, type, "#{at}: #{field}")
      :error -> ["#{at}: #{field} is required"]
    end
  end

  defp optional(map, field, type, at) do
    case Map.fetch(map, field) do
      {:ok, value} -> type_errors(value, type, "#{at}: #{field}")
      :error -> []
    end
  end

  defp type_errors(value, type, at),
    do: if(valid?(value, type), do: [], else: ["#{at} #{expected(type)}"])

  defp valid?(value, :url) when is_binary(value), do: http_url?(URI.parse(value))
  defp valid?(value, :origin) when is_binary(value), do: origin?(URI.parse(value))
  defp valid?(value, :selector) when is_binary(value), do: value != ""
  defp valid?(value, :string), do: is_binary(value)
  defp valid?(value, :boolean), do: is_boolean(value)
  defp valid?(value, :date_type), do: value == "date"

  defp valid?(value, :wait_seconds) when is_number(value),
    do: value > 0 and value <= @max_wait_seconds

  defp valid?(value, :timeout_ms) when is_integer(value), do: value in 1..@max_timeout_ms
  defp valid?(value, :screenshot_name) when is_binary(value), do: value =~ @screenshot_name
  defp valid?(_value, _type), do: false

  defp http_url?(%URI{scheme: scheme, host: host}) when scheme in ["http", "https"],
    do: is_binary(host) and host != ""

  defp http_url?(_uri), do: false

  # An origin is a URL's scheme, host and port, and nothing more.
  defp origin?(%URI{path: path, query: nil, fragment: nil, userinfo: nil} = uri)
       when path in [nil, ""],
       do: http_url?(uri)

  defp origin?(_uri), do: false

  defp expected(:url), do: "must be an http(s) URL with a host"
  defp expected(:origin), do: "must be an http(s) origin: scheme://host[:port]"
  defp expected(:selector), do: "must be a non-empty string"
  defp expected(:string), do: "must be a string"
  defp expected(:boolean), do: "must be true or false"
  defp expected(:date_type), do: "must be \"date\""

  defp expected(:wait_seconds),
    do: "must be a number, greater than 0 and at most #{@max_wait_seconds}"

  defp expected(:timeout_ms), do: "must be an integer from 1 to #{@max_timeout_ms}"
  defp expected(:screenshot_name), do: "must match [a-z0-9_-]{1,40}"
end
