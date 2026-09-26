defmodule AlexClaw.Skills.ApiRequest do
  @moduledoc """
  Generic REST API skill. Makes HTTP requests to external endpoints.
  Configurable via step config: method, url, headers, body.
  Supports {input} placeholder interpolation in url and body.

  When an API resource is assigned to the workflow, the skill resolves
  URL and auth from the resource's discovery metadata. Config `{base_url}`
  placeholders are replaced with the resource's base URL + base path.
  A `"path"` key in config constructs the full URL from the resource.
  Auth headers from `metadata["auth"]` are merged into the request.

  The skill never holds a credential: the step's and the resource's reach it
  as placeholders, filled at send for the host the request goes to, and only
  that host (`AlexClaw.Net.Credentials`). A credential a request would carry
  elsewhere, or across a redirect to another host, is refused:
  `{:error, {:credential_refused, message}}`.
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec external() :: boolean()
  def external, do: true
  @impl true
  @spec description() :: String.t()
  def description,
    do: "Generic REST client — GET/POST/PUT/PATCH/DELETE with {input} interpolation"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_2xx, :on_4xx, :on_5xx, :on_timeout, :on_error]

  # A 4xx, a 5xx or a timeout is a failed request: routable, but a run that
  # does not route it fails rather than handing the error body on.
  @impl true
  def error_routes, do: [:on_4xx, :on_5xx, :on_timeout, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  # Request headers carry the credentials an API asks for (Authorization,
  # x-api-key): those entries are kept in OpenBao (AlexClaw.Workflows.StepSecrets).
  @impl true
  @spec secret_config_keys() :: [String.t()]
  def secret_config_keys, do: ["headers"]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"method": "GET", "url": "https://...", "headers": {}, "body": ""}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"method" => "GET", "url" => "", "headers" => %{}, "body" => ""}

  @impl true
  @spec config_schema() :: AlexClaw.Skill.config_schema()
  def config_schema do
    %{
      "url" => %{type: :string, required: false},
      "method" => %{type: :string, required: false},
      "headers" => %{type: :map, required: false},
      "body" => %{type: :string, required: false},
      "path" => %{type: :string, required: false}
    }
  end

  # A request needs somewhere to go: a url, or a path joined to an assigned
  # api resource's base url when it runs.
  @impl true
  @spec validate_config(map()) :: :ok | {:error, [String.t()]}
  def validate_config(%{"url" => url}) when is_binary(url) and url != "",
    do: url |> URI.parse() |> without_userinfo()

  def validate_config(%{"path" => path}) when is_binary(path) and path != "", do: :ok

  def validate_config(_config),
    do: {:error, ["url: required (or a path, with an assigned api resource)"]}

  # The request's host and path, for the log: a query string may carry a token.
  defp loggable(url) do
    uri = URI.parse(url)
    URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port, path: uri.path})
  end

  # A password in a URL is stored, shown and logged with it: a credential goes
  # in a header, where it is kept as a secret.
  defp without_userinfo(%URI{userinfo: nil}), do: :ok

  defp without_userinfo(_uri),
    do: {:error, ["url: must not carry a user name or password (put the credential in a header)"]}

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "GET" => %{"method" => "GET", "url" => "https://...", "headers" => %{}},
      "POST" => %{
        "method" => "POST",
        "url" => "https://...",
        "headers" => %{"content-type" => "application/json"},
        "body" => "{}"
      }
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "HTTP request parameters: method, url, headers, body. The response becomes the next step's input."

  require Logger

  alias AlexClaw.Net.Credentials

  @methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete
  }
  @allowed_methods Map.keys(@methods)

  @impl true
  @spec run(map()) :: {:ok, any()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    input = args[:input]
    resources = args[:resources] || []

    api_resource = find_api_resource(resources)
    config = enrich_config(config, api_resource)

    method = String.upcase(config["method"] || "GET")
    url = interpolate(config["url"] || "", input)
    headers = parse_headers(config["headers"])
    body = interpolate(config["body"] || "", input)

    if url == "" do
      {:error, :no_url}
    else
      if method in @allowed_methods do
        execute_request(method, url, headers, body)
      else
        {:error, {:invalid_method, method}}
      end
    end
  end

  defp find_api_resource(resources) when is_list(resources) do
    Enum.find(resources, fn r -> r.type == "api" and r.enabled end)
  end

  defp find_api_resource(_), do: nil

  defp enrich_config(config, nil), do: config

  defp enrich_config(config, resource) do
    base_url = get_in(resource.metadata || %{}, ["discovery", "base_url"]) || resource.url || ""
    base_path = get_in(resource.metadata || %{}, ["discovery", "openapi", "base_path"]) || ""

    config
    |> resolve_url(base_url, base_path)
    |> merge_auth_headers(resource.metadata)
  end

  defp resolve_url(%{"url" => url} = config, base_url, base_path)
       when is_binary(url) and url != "" do
    if String.contains?(url, "{base_url}") do
      Map.put(config, "url", String.replace(url, "{base_url}", base_url <> base_path))
    else
      config
    end
  end

  defp resolve_url(%{"path" => path} = config, base_url, base_path) when is_binary(path) do
    config
    |> Map.put("url", base_url <> base_path <> path)
    |> Map.delete("path")
  end

  defp resolve_url(config, _base_url, _base_path), do: config

  defp merge_auth_headers(config, %{"auth" => %{"header" => name, "value" => value}})
       when is_binary(name) and is_binary(value) do
    existing = config["headers"] || %{}
    Map.put(config, "headers", Map.put_new(existing, name, value))
  end

  defp merge_auth_headers(config, _metadata), do: config

  # The request is built and sent through the step that attaches credentials
  # at send (AlexClaw.Net.Credentials): the step's and its resource's are
  # placeholders here, filled only for the host the request actually goes to.
  defp execute_request(method, url, headers, body) do
    Logger.info("ApiRequest #{method} #{loggable(url)}", skill: :api_request)

    [method: Map.fetch!(@methods, method), url: url, headers: headers, receive_timeout: 30_000]
    |> Keyword.merge(body_opts(method, body))
    |> Req.new()
    |> Credentials.attach()
    |> Req.request()
    |> request_result()
  end

  defp body_opts(method, _body) when method in ~w(GET DELETE), do: []
  defp body_opts(_method, body), do: json_or_body(body)

  defp request_result({:ok, %{status: status, body: resp_body}}) when status in 200..299,
    do: {:ok, format_response(resp_body), :on_2xx}

  defp request_result({:ok, %{status: status, body: resp_body}}) when status in 400..499 do
    Logger.warning("ApiRequest failed: #{status}", skill: :api_request)
    {:ok, format_response(resp_body), :on_4xx}
  end

  defp request_result({:ok, %{status: status, body: resp_body}}) when status in 500..599 do
    Logger.warning("ApiRequest failed: #{status}", skill: :api_request)
    {:ok, format_response(resp_body), :on_5xx}
  end

  defp request_result({:ok, %{status: status, body: resp_body}}) do
    Logger.warning("ApiRequest failed: #{status}", skill: :api_request)
    {:error, {:http, status, format_response(resp_body)}}
  end

  defp request_result({:error, %Req.TransportError{reason: :timeout}}) do
    Logger.warning("ApiRequest timeout", skill: :api_request)
    {:ok, nil, :on_timeout}
  end

  defp request_result({:error, %Credentials.Refused{} = refused}) do
    Logger.warning("ApiRequest #{Exception.message(refused)}", skill: :api_request)
    {:error, {:credential_refused, Exception.message(refused)}}
  end

  defp request_result({:error, reason}) do
    Logger.error("ApiRequest error: #{inspect(reason)}", skill: :api_request)
    {:error, reason}
  end

  defp interpolate(template, nil), do: template

  defp interpolate(template, input) when is_binary(input) do
    template
    |> String.replace("{input_encoded}", URI.encode(input))
    |> String.replace("{input}", input)
  end

  defp interpolate(template, input) when is_map(input) do
    json =
      case Jason.encode(input) do
        {:ok, encoded} -> encoded
        {:error, _} -> inspect(input)
      end

    template
    |> String.replace("{input_encoded}", URI.encode(json))
    |> String.replace("{input}", json)
  end

  defp interpolate(template, input) do
    str = inspect(input)

    template
    |> String.replace("{input_encoded}", URI.encode(str))
    |> String.replace("{input}", str)
  end

  defp parse_headers(nil), do: []

  defp parse_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp parse_headers(_), do: []

  defp json_or_body(""), do: []

  defp json_or_body(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> [json: parsed]
      {:error, _} -> [body: body]
    end
  end

  defp format_response(body) when is_binary(body), do: body

  defp format_response(body) when is_map(body) or is_list(body),
    do: Jason.encode!(body, pretty: true)

  defp format_response(body), do: inspect(body)
end
