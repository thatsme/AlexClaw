defmodule AlexClaw.Skills.ApiRequest do
  @moduledoc """
  Generic REST API skill. Makes HTTP requests to external endpoints.
  Configurable via step config: method, url, headers, body.
  Supports {input} placeholder interpolation in url and body.
  """
  @behaviour AlexClaw.Skill
  @impl true
  @spec external() :: boolean()
  def external, do: true
  @impl true
  @spec description() :: String.t()
  def description, do: "Generic REST client — GET/POST/PUT/PATCH/DELETE with {input} interpolation"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_2xx, :on_4xx, :on_5xx, :on_timeout, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"method": "GET", "url": "https://...", "headers": {}, "body": ""}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"method" => "GET", "url" => "", "headers" => %{}, "body" => ""}

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "GET" => %{"method" => "GET", "url" => "https://...", "headers" => %{}},
      "POST" => %{"method" => "POST", "url" => "https://...", "headers" => %{"content-type" => "application/json"}, "body" => "{}"}
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help, do: "HTTP request parameters: method, url, headers, body. The response becomes the next step's input."

  require Logger

  @allowed_methods ~w(GET POST PUT PATCH DELETE)

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
      unless method in @allowed_methods do
        {:error, {:invalid_method, method}}
      else
        execute_request(method, url, headers, body)
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

  defp execute_request(method, url, headers, body) do
    Logger.info("ApiRequest #{method} #{url}", skill: :api_request)

    opts = [headers: headers, receive_timeout: 30_000]

    result =
      case method do
        "GET" -> Req.get(url, opts)
        "DELETE" -> Req.delete(url, opts)
        "POST" -> Req.post(url, Keyword.merge(opts, json_or_body(body)))
        "PUT" -> Req.put(url, Keyword.merge(opts, json_or_body(body)))
        "PATCH" -> Req.request(Keyword.merge(opts, [method: :patch, url: url] ++ json_or_body(body)))
      end

    case result do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, format_response(resp_body), :on_2xx}

      {:ok, %{status: status, body: resp_body}} when status in 400..499 ->
        Logger.warning("ApiRequest failed: #{status}", skill: :api_request)
        {:ok, format_response(resp_body), :on_4xx}

      {:ok, %{status: status, body: resp_body}} when status in 500..599 ->
        Logger.warning("ApiRequest failed: #{status}", skill: :api_request)
        {:ok, format_response(resp_body), :on_5xx}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("ApiRequest failed: #{status}", skill: :api_request)
        {:error, {:http, status, format_response(resp_body)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        Logger.warning("ApiRequest timeout", skill: :api_request)
        {:ok, nil, :on_timeout}

      {:error, reason} ->
        Logger.error("ApiRequest error: #{inspect(reason)}", skill: :api_request)
        {:error, reason}
    end
  end

  defp interpolate(template, nil), do: template
  defp interpolate(template, input) when is_binary(input) do
    template
    |> String.replace("{input_encoded}", URI.encode(input))
    |> String.replace("{input}", input)
  end
  defp interpolate(template, input) when is_map(input) do
    json = case Jason.encode(input) do
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
  defp format_response(body) when is_map(body) or is_list(body), do: Jason.encode!(body, pretty: true)
  defp format_response(body), do: inspect(body)
end
