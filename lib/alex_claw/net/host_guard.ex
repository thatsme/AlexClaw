defmodule AlexClaw.Net.HostGuard do
  @moduledoc """
  Keeps an HTTP request away from internal destinations.

  `attach/2` replaces a Req request's adapter. For every call — the first
  request, each redirect hop and each retry — the adapter resolves the URL's
  host, refuses it if the name does not resolve or if any address it resolves
  to is internal, and then connects with Mint to the address it checked. The
  name is looked up once per call, so it cannot resolve to one address for the
  check and another for the connection. The certificate is verified, and SNI
  sent, for the name. Each call opens and closes its own connection: there is
  no pool.

  Internal means loopback, "this network", private (RFC 1918), shared
  (100.64/10), link-local, benchmarking (198.18/15), multicast, reserved and
  broadcast IPv4; `::1`, `::`, unique-local and link-local IPv6; and the
  IPv4-mapped IPv6 form of every IPv4 range.
  """

  import Bitwise

  defmodule BlockedError do
    @moduledoc "A request refused by `AlexClaw.Net.HostGuard` before any connection."
    defexception [:url, :reason]

    @type t :: %__MODULE__{url: String.t(), reason: :blocked_host | :invalid_url}

    @impl true
    def message(%{url: url, reason: reason}), do: "#{reason}: #{url}"
  end

  @default_receive_timeout 15_000

  # {first address as an integer, prefix length}
  @blocked_v4 [
    {0x00000000, 8},
    {0x0A000000, 8},
    {0x64400000, 10},
    {0x7F000000, 8},
    {0xA9FE0000, 16},
    {0xAC100000, 12},
    {0xC0A80000, 16},
    {0xC6120000, 15},
    {0xE0000000, 4},
    {0xF0000000, 4}
  ]

  @blocked_v6 [
    {0, 128},
    {1, 128},
    {0xFC00 <<< 112, 7},
    {0xFE80 <<< 112, 10}
  ]

  @doc """
  Checks a URL without making a request: `:ok` when it is http(s) and its host
  resolves only to public addresses.
  """
  @spec check_url(String.t()) :: :ok | {:error, :blocked_host | :invalid_url}
  def check_url(url) when is_binary(url) do
    with {:ok, uri} <- parse(url),
         {:ok, _address} <- checked_address(uri, MapSet.new()) do
      :ok
    end
  end

  @doc """
  Makes `request` go through the guarded adapter.

  `allow:` lists origins, as exact `"host:port"` strings, that are connected to
  without the address check. Raises `ArgumentError` if the request already has
  its own adapter or plug, which would run instead of the guard.
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = request, opts \\ []) do
    ensure_default_transport!(request)
    allow = MapSet.new(Keyword.get(opts, :allow, []))
    %{request | adapter: &run(&1, allow)}
  end

  defp ensure_default_transport!(%{options: %{plug: _}}),
    do: raise(ArgumentError, "the request has its own :plug, which would bypass the guard")

  defp ensure_default_transport!(%{adapter: adapter}) do
    unless adapter == (&Req.Steps.run_finch/1) do
      raise ArgumentError, "the request has its own :adapter, which would bypass the guard"
    end
  end

  # --- Adapter ---

  defp run(request, allow) do
    url = URI.to_string(request.url)

    with {:ok, uri} <- parse(url),
         {:ok, address} <- checked_address(uri, allow),
         {:ok, response} <- send_request(request, uri, address) do
      {request, response}
    else
      {:error, reason} when reason in [:blocked_host, :invalid_url] ->
        {request, %BlockedError{url: url, reason: reason}}

      {:error, exception} ->
        {request, exception}
    end
  end

  defp send_request(request, uri, address) do
    case connect(uri, address) do
      {:ok, conn} -> exchange(conn, request, uri)
      {:error, reason} -> as_req_error(reason)
    end
  end

  defp connect(uri, address) do
    Mint.HTTP.connect(scheme(uri.scheme), address, uri.port,
      hostname: uri.host,
      protocols: [:http1],
      mode: :passive,
      transport_opts: [inet6: tuple_size(address) == 8]
    )
  end

  defp scheme("http"), do: :http
  defp scheme("https"), do: :https

  # One request on the connection, then it is closed whatever the outcome.
  defp exchange(conn, request, uri) do
    timeout = Req.Request.get_option(request, :receive_timeout, @default_receive_timeout)
    method = request.method |> Atom.to_string() |> String.upcase()
    headers = for {name, values} <- request.headers, value <- values, do: {name, value}

    {conn, result} =
      case Mint.HTTP.request(conn, method, request_target(uri), headers, request.body) do
        {:ok, conn, ref} ->
          receive_response(conn, ref, timeout, %{status: nil, headers: [], body: []})

        {:error, conn, reason} ->
          {conn, {:error, reason}}
      end

    Mint.HTTP.close(conn)
    finish(result)
  end

  defp request_target(%URI{path: path, query: nil}), do: path || "/"
  defp request_target(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"

  defp receive_response(conn, ref, timeout, acc) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, parts} -> collect(parts, conn, ref, timeout, acc)
      {:error, conn, reason, _parts} -> {conn, {:error, reason}}
    end
  end

  defp collect([], conn, ref, timeout, acc), do: receive_response(conn, ref, timeout, acc)
  defp collect([{:done, ref} | _], conn, ref, _timeout, acc), do: {conn, {:ok, acc}}

  defp collect([part | rest], conn, ref, timeout, acc),
    do: collect(rest, conn, ref, timeout, add_part(part, ref, acc))

  defp add_part({:status, ref, status}, ref, acc), do: %{acc | status: status}
  defp add_part({:headers, ref, headers}, ref, acc), do: %{acc | headers: acc.headers ++ headers}
  defp add_part({:data, ref, data}, ref, acc), do: %{acc | body: [acc.body | data]}
  defp add_part(_other, _ref, acc), do: acc

  defp finish({:ok, acc}) do
    {:ok,
     Req.Response.new(
       status: acc.status,
       headers: acc.headers,
       body: IO.iodata_to_binary(acc.body)
     )}
  end

  defp finish({:error, reason}), do: as_req_error(reason)

  # Req's retry step recognises its own error structs, not Mint's.
  defp as_req_error(%Mint.TransportError{reason: reason}),
    do: {:error, %Req.TransportError{reason: reason}}

  defp as_req_error(%Mint.HTTPError{reason: reason}),
    do: {:error, %Req.HTTPError{protocol: :http1, reason: reason}}

  # --- URL and address checks ---

  defp parse(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp checked_address(uri, allow) do
    addresses = resolve(uri.host)
    allowed? = MapSet.member?(allow, "#{uri.host}:#{uri.port}")

    cond do
      addresses == [] -> {:error, :blocked_host}
      allowed? -> {:ok, hd(addresses)}
      Enum.any?(addresses, &internal?/1) -> {:error, :blocked_host}
      true -> {:ok, hd(addresses)}
    end
  end

  # IPv4 first: it is the family a container can reach.
  defp resolve(host) do
    name = String.to_charlist(host)
    lookup(name, :inet) ++ lookup(name, :inet6)
  end

  defp lookup(name, family) do
    case :inet.getaddrs(name, family) do
      {:ok, addresses} -> addresses
      {:error, _} -> []
    end
  end

  defp internal?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: internal?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})

  defp internal?({a, b, c, d}),
    do: in_ranges?(a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d, 32, @blocked_v4)

  defp internal?(address) when tuple_size(address) == 8 do
    value = address |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 16 ||| &1))
    in_ranges?(value, 128, @blocked_v6)
  end

  defp in_ranges?(value, bits, ranges),
    do:
      Enum.any?(ranges, fn {first, prefix} ->
        value >>> (bits - prefix) == first >>> (bits - prefix)
      end)
end
