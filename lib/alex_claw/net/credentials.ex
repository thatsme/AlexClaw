defmodule AlexClaw.Net.Credentials do
  @moduledoc """
  Attaches credentials to a request at send, in declared slots only, for the
  host it actually goes to (S8 H2, H3, H7; S9 fix review N1; THREAT_MODEL P5).

  A skill never holds a credential: its step config and its resources carry
  placeholders, `{{secret:NAME}}` (`AlexClaw.Secrets.Owned.placeholder/1`).
  No text is ever searched for them — a placeholder in a URL, a body, a
  message or a step's input is sent as written. A value is attached only in a
  slot the caller declares:

    * `attach/2` — named request headers, each given a placeholder standing
      alone (a step's configured headers and its resource's auth header in
      `api_request`; a skill's `:secret_headers` in `SkillAPI.http_request/4`);
    * `resolved/2` — one placeholder for one URL, where the API puts its
      credential in the path (a `telegram_notify` step's own bot token).

  Each is filled only if the running step was given that secret
  (`AlexClaw.Auth.SafeExecutor.secret_allowed?/1`; a process with no
  allow-list gets none) and is resolved for `host:<the request's host>`: the
  binding is checked here, at send, against where the request goes, whatever
  built its URL. A request that carries a credential — attached here, or set
  by AlexClaw's own code and marked with `guard_redirects/2` — is not
  followed to another host: such a redirect is refused, whatever the header
  (Req strips only `Authorization`).

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

  @typedoc "Declared header slots: header name => a placeholder standing alone."
  @type slots :: %{optional(String.t()) => String.t()} | [{String.t(), String.t()}]

  @doc """
  `request` with each header in `slots` set at send to the value its
  placeholder stands for, and its redirects guarded. Nothing else in the
  request is filled.
  """
  @spec attach(Req.Request.t(), slots()) :: Req.Request.t()
  def attach(%Req.Request{} = request, slots \\ %{}) do
    request
    |> Req.Request.put_private(:credential_slots, Enum.to_list(slots))
    |> Req.Request.append_request_steps(fill_credentials: &fill/1)
    |> guard_redirects()
  end

  @doc """
  The value `placeholder` stands for, for the host of `url`: for a credential
  the API takes in the URL itself. The same checks as `attach/2`; a refusal
  is `{:error, %Refused{}}`.
  """
  @spec resolved(String.t(), String.t()) :: {:ok, String.t()} | {:error, Exception.t()}
  def resolved(placeholder, url) when is_binary(placeholder) and is_binary(url) do
    host = URI.parse(url).host

    placeholder
    |> slot_name()
    |> value_for(host)
    |> resolved_as(host)
  end

  defp resolved_as({:ok, _value} = ok, _host), do: ok

  defp resolved_as({:error, name, reason}, host),
    do: {:error, %Refused{name: name, host: host, reason: reason}}

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
    host = request.url.host

    request
    |> Req.Request.get_private(:credential_slots, [])
    |> Enum.reduce_while({:ok, []}, fn {header, placeholder}, {:ok, acc} ->
      placeholder |> slot_name() |> value_for(host) |> collected(header, acc)
    end)
    |> filled(request, host)
  end

  # A slot holds a placeholder standing alone, or it is refused.
  defp slot_name(placeholder), do: {placeholder, Owned.placeholder_name(placeholder)}

  # The slot's text is not echoed: it is not a placeholder, so it may be anything.
  defp value_for({_placeholder, nil}, _host), do: {:error, "(slot)", :not_a_placeholder}

  defp value_for({_placeholder, name}, host),
    do: name |> SafeExecutor.secret_allowed?() |> allowed(name, host)

  defp allowed(false, name, _host), do: {:error, name, :not_given}

  defp allowed(true, name, host),
    do: name |> Secrets.resolve(for: "host:" <> to_string(host)) |> named(name)

  defp named({:ok, value}, _name), do: {:ok, value}
  defp named({:error, reason}, name), do: {:error, name, reason}

  defp collected({:ok, value}, header, acc), do: {:cont, {:ok, [{header, value} | acc]}}
  defp collected({:error, name, reason}, _header, _acc), do: {:halt, {:error, name, reason}}

  defp filled({:ok, []}, request, _host), do: request

  defp filled({:ok, headers}, request, _host) do
    headers
    |> Enum.reduce(request, fn {header, value}, acc ->
      Req.Request.put_header(acc, header, value)
    end)
    |> Req.Request.put_private(:credentialed, true)
  end

  defp filled({:error, name, reason}, request, host),
    do: {request, %Refused{name: name, host: host, reason: reason}}

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
