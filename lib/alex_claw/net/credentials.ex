defmodule AlexClaw.Net.Credentials do
  @moduledoc """
  Attaches credentials to a request at send, for the host it actually goes
  to (S8 H2, H3, H7; THREAT_MODEL P5).

  A skill never holds a credential: its step config and its resources carry
  placeholders, `{{secret:NAME}}` (`AlexClaw.Secrets.Owned.placeholder/1`).
  `attach/1` adds the last request step before the network, which fills each
  placeholder in the URL, the headers and the body:
    * only a placeholder the running step was given
      (`AlexClaw.Auth.SafeExecutor.secret_allowed?/1`) — a skill naming
      another secret is refused;
    * resolved for `host:<the request's host>` — the binding is checked here,
      at send, against where the request goes, whatever built its URL.
  A request that carries a credential — filled here, or set by AlexClaw's own
  code and marked with `guard_redirects/1` — is not followed to another host:
  such a redirect is refused, whatever the header (Req strips only
  `Authorization`).

  A refusal is `AlexClaw.Net.Credentials.Refused`, which names the secret and
  the host, never a value.
  """
  alias AlexClaw.Auth.SafeExecutor
  alias AlexClaw.Secrets
  alias AlexClaw.Secrets.Owned

  defmodule Refused do
    @moduledoc "A credential not attached, or a credentialed request not redirected."
    defexception [:name, :host, :reason]

    @impl true
    def message(%{reason: :cross_host_redirect, host: host}),
      do: "credential refused: a redirect to #{host} would carry it to another host"

    def message(%{name: name, host: host, reason: reason}),
      do: "credential #{name} refused for #{host}: #{inspect(reason)}"
  end

  @doc "`request` with its placeholders filled at send, and its redirects guarded."
  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = request) do
    request
    |> Req.Request.append_request_steps(fill_credentials: &fill/1)
    |> guard_redirects()
  end

  @doc """
  `request` refusing a redirect to another host once it carries a credential.
  AlexClaw's own code that sets a credential itself (an LLM provider's key)
  passes `credentialed: true`.
  """
  @spec guard_redirects(Req.Request.t(), keyword()) :: Req.Request.t()
  def guard_redirects(%Req.Request{} = request, opts \\ []) do
    request
    |> Req.Request.put_private(:credentialed, Keyword.get(opts, :credentialed, false))
    |> Req.Request.prepend_response_steps(guard_redirect: &guard/1)
  end

  # --- request step ---

  defp fill(%Req.Request{} = request) do
    request
    |> placeholders()
    |> filled(request)
  end

  defp placeholders(request) do
    [URI.to_string(request.url), body_text(request.body) | header_values(request)]
    |> Enum.flat_map(&Owned.placeholder_names/1)
    |> Enum.uniq()
  end

  defp header_values(request),
    do: for({_name, values} <- request.headers, value <- List.wrap(values), do: value)

  defp body_text(body) when is_binary(body), do: body
  defp body_text(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp body_text(_body), do: ""

  defp filled([], request), do: request

  defp filled(names, request) do
    host = request.url.host

    names
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, values} ->
      name |> value_for(host) |> collected(name, values)
    end)
    |> substituted(request, host)
  end

  defp value_for(name, host), do: allowed(SafeExecutor.secret_allowed?(name), name, host)

  defp allowed(false, _name, _host), do: {:error, :not_given}
  defp allowed(true, name, host), do: Secrets.resolve(name, for: "host:" <> to_string(host))

  defp collected({:ok, value}, name, values), do: {:cont, {:ok, Map.put(values, name, value)}}
  defp collected({:error, reason}, name, _values), do: {:halt, {:error, name, reason}}

  defp substituted({:error, name, reason}, request, host),
    do: {request, %Refused{name: name, host: host, reason: reason}}

  defp substituted({:ok, values}, request, _host) do
    fill_in = &Owned.fill_placeholders(&1, values)

    %{
      request
      | url: request.url |> URI.to_string() |> fill_in.() |> URI.parse(),
        headers:
          Map.new(request.headers, fn {k, vs} -> {k, Enum.map(List.wrap(vs), fill_in)} end),
        body: filled_body(request.body, fill_in)
    }
    |> Req.Request.put_private(:credentialed, true)
  end

  defp filled_body(body, fill_in) when is_binary(body), do: fill_in.(body)

  defp filled_body(body, fill_in) when is_list(body),
    do: body |> IO.iodata_to_binary() |> fill_in.()

  defp filled_body(body, _fill_in), do: body

  # --- response step ---

  defp guard({request, response}) do
    redirected_elsewhere(credentialed?(request), request, response)
  end

  defp credentialed?(request), do: Req.Request.get_private(request, :credentialed, false)

  defp redirected_elsewhere(true, request, %{status: status} = response)
       when status in 301..308 do
    request
    |> location(response)
    |> another_host(request.url)
    |> refused_redirect(request, response)
  end

  defp redirected_elsewhere(_credentialed, request, response), do: {request, response}

  defp location(request, response) do
    case Req.Response.get_header(response, "location") do
      [target | _] -> URI.merge(request.url, target)
      [] -> nil
    end
  end

  defp another_host(nil, _from), do: false

  defp another_host(to, from),
    do: {to.scheme, to.host, to.port} != {from.scheme, from.host, from.port}

  defp refused_redirect(false, request, response), do: {request, response}

  defp refused_redirect(true, request, response) do
    target = request |> location(response) |> Map.get(:host)
    {request, %Refused{host: target, reason: :cross_host_redirect}}
  end
end
