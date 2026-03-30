defmodule AlexClaw.Resources.ApiDiscovery do
  @moduledoc """
  Async probe and OpenAPI spec discovery for API resources.

  When an API resource is created or updated, this module runs a background task
  that probes the URL and attempts to discover an OpenAPI/Swagger spec. Results
  are stored in `metadata["discovery"]` on the resource.
  """

  require Logger

  alias AlexClaw.Resources
  alias AlexClaw.Resources.Resource

  @pubsub AlexClaw.PubSub
  @discovery_topic "resources:discovery"

  @spec_paths ~w(
    /openapi.json
    /swagger.json
    /api-docs
    /v3/api-docs
    /swagger/v1/swagger.json
  )

  @probe_timeout 10_000
  @spec_max_bytes 2_097_152
  @max_endpoints 100

  @spec topic() :: String.t()
  def topic, do: @discovery_topic

  @spec run_async(Resource.t()) :: {:ok, pid()} | :ignore
  def run_async(%Resource{type: "api", url: url} = resource) when is_binary(url) and url != "" do
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      discover(resource)
    end)
  end

  def run_async(_resource), do: :ignore

  defp discover(resource) do
    mark_status(resource, "running")

    url = String.trim(resource.url)
    probe_result = probe(url)
    base_url = derive_base_url(url)
    openapi_result = discover_openapi(base_url, url)

    discovery = %{
      "status" => "completed",
      "probed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "base_url" => base_url,
      "probe" => probe_result,
      "openapi" => openapi_result,
      "error" => nil
    }

    save_discovery(resource, discovery)
    broadcast(resource.id, :completed)

    Logger.info("[ApiDiscovery] Completed for #{resource.name} (#{resource.url})",
      resource_id: resource.id
    )
  rescue
    e ->
      error_msg = Exception.message(e)

      save_discovery(resource, %{
        "status" => "failed",
        "probed_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "error" => error_msg
      })

      broadcast(resource.id, {:failed, error_msg})

      Logger.warning("[ApiDiscovery] Failed for #{resource.name}: #{error_msg}",
        resource_id: resource.id
      )
  end

  @spec probe(String.t()) :: map()
  defp probe(url) do
    case Req.head(url, receive_timeout: @probe_timeout, retry: false, redirect: true, max_redirects: 3) do
      {:ok, %{status: status, headers: headers}} ->
        %{
          "http_status" => status,
          "content_type" => get_header(headers, "content-type"),
          "server" => get_header(headers, "server")
        }

      {:error, _reason} ->
        case Req.get(url, receive_timeout: @probe_timeout, retry: false, redirect: true, max_redirects: 3) do
          {:ok, %{status: status, headers: headers}} ->
            %{
              "http_status" => status,
              "content_type" => get_header(headers, "content-type"),
              "server" => get_header(headers, "server")
            }

          {:error, reason} ->
            %{
              "http_status" => nil,
              "content_type" => nil,
              "server" => nil,
              "error" => inspect(reason)
            }
        end
    end
  end

  @spec derive_base_url(String.t()) :: String.t()
  defp derive_base_url(url) do
    uri = URI.parse(url)

    port_suffix =
      case {uri.scheme, uri.port} do
        {"https", 443} -> ""
        {"http", 80} -> ""
        {_, nil} -> ""
        {_, port} -> ":#{port}"
      end

    "#{uri.scheme}://#{uri.host}#{port_suffix}"
  end

  @spec discover_openapi(String.t(), String.t()) :: map() | nil
  defp discover_openapi(base_url, full_url) do
    # Try spec paths relative to the full URL first, then the base host
    candidates =
      Enum.map(@spec_paths, fn path -> String.trim_trailing(full_url, "/") <> path end) ++
        if full_url != base_url do
          Enum.map(@spec_paths, fn path -> base_url <> path end)
        else
          []
        end

    candidates
    |> Enum.uniq()
    |> Enum.find_value(fn spec_url ->
      case Req.get(spec_url,
             receive_timeout: @probe_timeout,
             retry: false,
             max_retries: 0
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          # Req auto-decoded JSON — check if it's an OpenAPI/Swagger spec
          if Map.has_key?(body, "openapi") or Map.has_key?(body, "swagger") do
            parse_openapi_spec(body, spec_url)
          end

        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          # Non-JSON response or Req didn't decode — try manual parse
          if byte_size(body) <= @spec_max_bytes do
            case Jason.decode(body) do
              {:ok, json} when is_map(json) ->
                if Map.has_key?(json, "openapi") or Map.has_key?(json, "swagger") do
                  parse_openapi_spec(json, spec_url)
                end

              _ ->
                nil
            end
          end

        _ ->
          nil
      end
    end)
  end

  @spec parse_openapi_spec(map(), String.t()) :: map()
  defp parse_openapi_spec(spec, spec_url) do
    %{
      "spec_url" => spec_url,
      "title" => get_in(spec, ["info", "title"]),
      "version" => get_in(spec, ["info", "version"]),
      "base_path" => extract_base_path(spec),
      "auth_schemes" => extract_auth_schemes(spec),
      "endpoints" => extract_endpoints(spec)
    }
  end

  defp extract_base_path(spec) do
    cond do
      # OpenAPI 3.x — servers[0].url
      servers = spec["servers"] ->
        case List.first(servers || []) do
          %{"url" => url} when is_binary(url) ->
            uri = URI.parse(url)
            uri.path || ""

          _ ->
            ""
        end

      # Swagger 2.x — basePath
      base_path = spec["basePath"] ->
        base_path

      true ->
        ""
    end
  end

  defp extract_auth_schemes(spec) do
    schemes =
      cond do
        # OpenAPI 3.x
        components = get_in(spec, ["components", "securitySchemes"]) ->
          Map.keys(components)

        # Swagger 2.x
        definitions = spec["securityDefinitions"] ->
          Map.keys(definitions)

        true ->
          []
      end

    Enum.take(schemes, 20)
  end

  defp extract_endpoints(spec) do
    paths = spec["paths"] || %{}

    http_methods = ~w(get post put patch delete head options)

    paths
    |> Enum.flat_map(fn {path, methods} ->
      methods
      |> Enum.filter(fn {method, _} -> method in http_methods end)
      |> Enum.map(fn {method, details} ->
        %{
          "method" => String.upcase(method),
          "path" => path,
          "summary" => extract_summary(details)
        }
      end)
    end)
    |> Enum.sort_by(fn ep -> {ep["path"], ep["method"]} end)
    |> Enum.take(@max_endpoints)
  end

  defp extract_summary(details) when is_map(details) do
    details["summary"] || details["description"] || ""
  end

  defp extract_summary(_), do: ""

  defp get_header(headers, name) when is_map(headers) do
    Map.get(headers, name)
  end

  defp get_header(headers, name) when is_list(headers) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp get_header(_, _), do: nil

  defp mark_status(resource, status) do
    existing = resource.metadata || %{}
    discovery = Map.get(existing, "discovery", %{})
    updated_discovery = Map.put(discovery, "status", status)
    updated_metadata = Map.put(existing, "discovery", updated_discovery)

    Resources.update_resource(resource, %{metadata: updated_metadata}, skip_discovery: true)
    broadcast(resource.id, :running)
  end

  defp save_discovery(resource, discovery_map) do
    case Resources.get_resource(resource.id) do
      {:ok, fresh_resource} ->
        existing = fresh_resource.metadata || %{}
        updated = Map.put(existing, "discovery", discovery_map)
        Resources.update_resource(fresh_resource, %{metadata: updated}, skip_discovery: true)

      {:error, :not_found} ->
        Logger.warning("[ApiDiscovery] Resource #{resource.id} no longer exists, skipping save")
    end
  end

  defp broadcast(resource_id, status) do
    Phoenix.PubSub.broadcast(@pubsub, @discovery_topic, {:discovery_updated, resource_id, status})
  end
end
