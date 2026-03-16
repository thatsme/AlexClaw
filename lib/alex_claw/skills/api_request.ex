defmodule AlexClaw.Skills.ApiRequest do
  @moduledoc """
  Generic REST API skill. Makes HTTP requests to external endpoints.
  Configurable via step config: method, url, headers, body.
  Supports {input} placeholder interpolation in url and body.
  """
  @behaviour AlexClaw.Skill
  @impl true
  def description, do: "Generic REST client — GET/POST/PUT/PATCH/DELETE with {input} interpolation"
  require Logger

  @allowed_methods ~w(GET POST PUT PATCH DELETE)

  @impl true
  @spec run(map()) :: {:ok, any()} | {:error, any()}
  def run(args) do
    config = args[:config] || %{}
    input = args[:input]

    method = String.upcase(config["method"] || "GET")
    url = interpolate(config["url"] || "", input)
    headers = parse_headers(config["headers"])
    body = interpolate(config["body"] || "", input)

    if url == "" do
      {:error, :no_url}
    else
      if method not in @allowed_methods do
        {:error, {:invalid_method, method}}
      else
        execute_request(method, url, headers, body)
      end
    end
  end

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
        output = format_response(resp_body)
        {:ok, output}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("ApiRequest failed: #{status}", skill: :api_request)
        {:error, {:http, status, format_response(resp_body)}}

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
    json = Jason.encode!(input)
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
