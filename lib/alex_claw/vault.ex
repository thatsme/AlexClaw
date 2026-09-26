defmodule AlexClaw.Vault do
  @moduledoc """
  AlexClaw's client for OpenBao, where every secret it uses is kept.

  It logs in with its AppRole — the role id and secret id `openbao-init`
  writes to AlexClaw's bootstrap mount — and holds the token in this process's
  state only, renewing it before it expires and logging in again when renewal
  fails. The connection is TLS, verified against the CA certificate in the same
  mount: a server that certificate did not sign is not OpenBao.

  Paths are relative to kv-v2's `secret/data/`. What AlexClaw may read or write
  is decided by OpenBao's policy for the AppRole, not by this module: a path
  outside it comes back `{:error, :forbidden}` from OpenBao.

  Every failure is a value: `{:error, :not_found}`, `{:error, :forbidden}`,
  `{:error, :invalid}` (OpenBao refused the request as malformed, such as a
  ciphertext it did not make) or `{:error, :vault_unavailable}` (unreachable,
  sealed, not configured, or not logged in). Nothing but paths and outcomes is
  ever logged.

  Options for `start_link/1`: `:address`, `:ca_file`, `:role_id_file`,
  `:secret_id_file` and `:name` (default `AlexClaw.Vault`). Every call takes
  `server:` to address another instance.
  """
  use GenServer

  require Logger

  @type error :: :not_found | :forbidden | :invalid | :vault_unavailable

  @transit_key "alexclaw"
  @call_timeout 15_000
  @http_timeout 5_000
  @first_retry 1_000
  @last_retry 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, config} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc """
  The secret at `path` (relative to `secret/data/`). `version:` reads a given
  version; kv keeps one per secret, so an older one is `{:error, :not_found}`.
  """
  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def read(path, opts \\ []) when is_binary(path),
    do: call(opts, {:read, path, Keyword.get(opts, :version)})

  @doc "Write `data` as the secret at `path`."
  @spec write(String.t(), map(), keyword()) :: :ok | {:error, error()}
  def write(path, data, opts \\ []) when is_binary(path) and is_map(data),
    do: call(opts, {:write, path, data})

  @doc "Delete the secret at `path` with every version and its metadata."
  @spec delete(String.t(), keyword()) :: :ok | {:error, error()}
  def delete(path, opts \\ []) when is_binary(path), do: call(opts, {:delete, path})

  @doc "Encrypt `plaintext` with OpenBao's transit key; AlexClaw never holds the key."
  @spec encrypt(binary(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def encrypt(plaintext, opts \\ []) when is_binary(plaintext),
    do: call(opts, {:encrypt, plaintext})

  @doc "Decrypt a ciphertext `encrypt/2` made."
  @spec decrypt(String.t(), keyword()) :: {:ok, binary()} | {:error, error()}
  def decrypt(ciphertext, opts \\ []) when is_binary(ciphertext),
    do: call(opts, {:decrypt, ciphertext})

  @doc """
  HMAC-SHA256 of `input` under OpenBao's transit key, as OpenBao writes it
  (`vault:v<n>:<base64>`); AlexClaw never holds the key, so the result cannot
  be recomputed or tried offline without OpenBao.
  """
  @spec hmac(binary(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def hmac(input, opts \\ []) when is_binary(input), do: call(opts, {:hmac, input})

  @doc """
  Whether `hmac` (as `hmac/2` wrote it) is the HMAC of `input` under the
  transit key. OpenBao compares in constant time; an HMAC of an older key
  version still verifies.
  """
  @spec verify_hmac(binary(), String.t(), keyword()) :: {:ok, boolean()} | {:error, error()}
  def verify_hmac(input, hmac, opts \\ []) when is_binary(input) and is_binary(hmac),
    do: call(opts, {:verify_hmac, input, hmac})

  @doc """
  Create the TOTP key `name` in OpenBao's TOTP engine, for `account` at
  `issuer`. Returns the otpauth URI and the QR code (a PNG) — the only time
  the secret leaves OpenBao, to be shown for enrolment.
  """
  @spec totp_create(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{url: String.t(), barcode: binary()}} | {:error, error()}
  def totp_create(name, issuer, account, opts \\ []),
    do: call(opts, {:totp_create, name, issuer, account})

  @doc """
  Import an existing TOTP secret (Base32) as the key `name`, replacing any:
  an authenticator enrolled before keeps working.
  """
  @spec totp_import(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, error()}
  def totp_import(name, key_b32, issuer, account, opts \\ []),
    do: call(opts, {:totp_import, name, key_b32, issuer, account})

  @doc """
  Whether `code` is a valid code for the TOTP key `name`. OpenBao refuses a
  code it has already accepted in its window, and a malformed one, as
  `{:error, :invalid}`.
  """
  @spec totp_validate(String.t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, error()}
  def totp_validate(name, code, opts \\ []), do: call(opts, {:totp_validate, name, code})

  @doc "The TOTP key `name`'s metadata (issuer, account, period…); never its secret."
  @spec totp_key(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def totp_key(name, opts \\ []), do: call(opts, {:totp_key, name})

  @doc "Delete the TOTP key `name`."
  @spec totp_delete(String.t(), keyword()) :: :ok | {:error, error()}
  def totp_delete(name, opts \\ []), do: call(opts, {:totp_delete, name})

  @doc "`:ok` when logged in to OpenBao."
  @spec status(keyword()) :: :ok | {:error, :vault_unavailable}
  def status(opts \\ []), do: call(opts, :status)

  # The client restarting, or not started, is OpenBao being unavailable to the
  # caller — a value, not the caller's crash.
  defp call(opts, request) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), request, @call_timeout)
  catch
    :exit, _reason -> {:error, :vault_unavailable}
  end

  # --- Server ---

  @impl true
  def init(config), do: {:ok, initial_state(config), {:continue, :login}}

  # A crash report or :sys.get_status/1 shows the state: never the token
  # (S8 M13).
  @impl true
  def format_status(status), do: Map.update(status, :state, nil, &hidden_token/1)

  defp hidden_token(%{token: nil} = state), do: state
  defp hidden_token(%{} = state), do: %{state | token: :redacted}
  defp hidden_token(state), do: state

  defp initial_state(config) do
    %{config: config, req: request_base(config), token: nil, retry: @first_retry, timer: nil}
  end

  defp request_base(config) do
    case {config[:address], config[:ca_file]} do
      {address, ca_file} when is_binary(address) and is_binary(ca_file) ->
        Req.new(
          base_url: address,
          retry: false,
          receive_timeout: @http_timeout,
          connect_options: [
            timeout: @http_timeout,
            transport_opts: [cacertfile: ca_file, verify: :verify_peer]
          ]
        )

      _not_configured ->
        nil
    end
  end

  @impl true
  def handle_continue(:login, %{req: nil} = s) do
    Logger.warning("OpenBao is not configured: every secret is unavailable")
    {:noreply, s}
  end

  def handle_continue(:login, s), do: {:noreply, logged_in(login(s), s)}

  @impl true
  def handle_call(:status, _from, s) do
    s = ensure_login(s)
    {:reply, logged_in?(s), s}
  end

  def handle_call(request, _from, s) do
    s = ensure_login(s)
    {reply, s} = with_token(s, request)
    {:reply, reply, s}
  end

  @impl true
  def handle_info(:login, s), do: {:noreply, logged_in(login(s), s)}

  def handle_info(:renew, s), do: {:noreply, renewed(renew(s), s)}

  # --- Login and renewal ---

  defp logged_in?(%{token: nil}), do: {:error, :vault_unavailable}
  defp logged_in?(_s), do: :ok

  defp ensure_login(%{token: nil, req: req} = s) when req != nil, do: logged_in(login(s), s)
  defp ensure_login(s), do: s

  defp login(s) do
    with {:ok, role_id} <- bootstrap_file(s.config[:role_id_file]),
         {:ok, secret_id} <- bootstrap_file(s.config[:secret_id_file]),
         {:ok, %{"auth" => auth}} <-
           request(s.req, nil, :post, "/v1/auth/approle/login", %{
             role_id: role_id,
             secret_id: secret_id
           }) do
      {:ok, auth}
    end
  end

  defp bootstrap_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, reason} -> {:error, {:bootstrap, path, reason}}
    end
  end

  defp bootstrap_file(_path), do: {:error, :not_configured}

  defp logged_in({:ok, %{"client_token" => token, "lease_duration" => ttl}}, s) do
    schedule(%{s | token: token, retry: @first_retry}, :renew, renew_after(ttl))
  end

  defp logged_in({:error, reason}, s) do
    Logger.warning("OpenBao login failed (#{describe(reason)}); retrying in #{s.retry} ms")
    schedule(%{s | token: nil, retry: min(s.retry * 2, @last_retry)}, :login, s.retry)
  end

  defp renew(%{token: nil}), do: {:error, :not_logged_in}

  defp renew(s) do
    case request(s.req, s.token, :post, "/v1/auth/token/renew-self", %{}) do
      {:ok, %{"auth" => auth}} -> {:ok, auth}
      error -> error
    end
  end

  # A token that cannot be renewed (past its max TTL, or revoked) is replaced
  # by a new login.
  defp renewed({:ok, %{"lease_duration" => ttl}}, s), do: schedule(s, :renew, renew_after(ttl))

  defp renewed({:error, _reason}, s), do: logged_in(login(s), %{s | token: nil})

  defp renew_after(ttl) when is_integer(ttl) and ttl > 0, do: div(ttl * 2, 3) * 1000
  defp renew_after(_ttl), do: @last_retry

  # One timer at a time: a new login or renewal replaces whatever was pending.
  defp schedule(s, message, after_ms) do
    if s.timer, do: Process.cancel_timer(s.timer)
    %{s | timer: Process.send_after(self(), message, after_ms)}
  end

  # --- Requests ---

  defp with_token(%{token: nil} = s, _request), do: {{:error, :vault_unavailable}, s}

  # A refusal may be a token OpenBao no longer honours: one fresh login, one
  # more try, and the second answer stands.
  defp with_token(s, request) do
    case perform(s, request) do
      {:error, :forbidden} -> retry_after_login(logged_in(login(s), %{s | token: nil}), request)
      reply -> {reply, s}
    end
  end

  defp retry_after_login(%{token: nil} = s, _request), do: {{:error, :vault_unavailable}, s}
  defp retry_after_login(s, request), do: {perform(s, request), s}

  defp perform(s, {:read, path, version}) do
    s.req
    |> request(s.token, :get, kv_path(path) <> version_query(version), nil)
    |> outcome(:read, path, fn %{"data" => %{"data" => data}} -> {:ok, data} end)
  end

  defp perform(s, {:delete, path}) do
    s.req
    |> request(s.token, :delete, "/v1/secret/metadata/" <> path, nil)
    |> outcome(:delete, path, fn _body -> :ok end)
  end

  defp perform(s, {:write, path, data}) do
    s.req
    |> request(s.token, :post, kv_path(path), %{data: data})
    |> outcome(:write, path, fn _body -> :ok end)
  end

  defp perform(s, {:encrypt, plaintext}) do
    s.req
    |> request(s.token, :post, "/v1/transit/encrypt/#{@transit_key}", %{
      plaintext: Base.encode64(plaintext)
    })
    |> outcome(:encrypt, @transit_key, fn %{"data" => %{"ciphertext" => c}} -> {:ok, c} end)
  end

  defp perform(s, {:decrypt, ciphertext}) do
    s.req
    |> request(s.token, :post, "/v1/transit/decrypt/#{@transit_key}", %{ciphertext: ciphertext})
    |> outcome(:decrypt, @transit_key, fn %{"data" => %{"plaintext" => p}} ->
      {:ok, Base.decode64!(p)}
    end)
  end

  defp perform(s, {:hmac, input}) do
    s.req
    |> request(s.token, :post, "/v1/transit/hmac/#{@transit_key}", %{input: Base.encode64(input)})
    |> outcome(:hmac, @transit_key, fn %{"data" => %{"hmac" => hmac}} -> {:ok, hmac} end)
  end

  defp perform(s, {:verify_hmac, input, hmac}) do
    s.req
    |> request(s.token, :post, "/v1/transit/verify/#{@transit_key}", %{
      input: Base.encode64(input),
      hmac: hmac
    })
    |> outcome(:verify, @transit_key, fn %{"data" => %{"valid" => valid}} -> {:ok, valid} end)
  end

  defp perform(s, {:totp_create, name, issuer, account}) do
    s.req
    |> request(s.token, :post, "/v1/totp/keys/#{name}", %{
      generate: true,
      exported: true,
      issuer: issuer,
      account_name: account,
      skew: 1
    })
    |> outcome(:totp_create, name, fn %{"data" => %{"url" => url, "barcode" => barcode}} ->
      {:ok, %{url: url, barcode: Base.decode64!(barcode)}}
    end)
  end

  defp perform(s, {:totp_import, name, key_b32, issuer, account}) do
    s.req
    |> request(s.token, :post, "/v1/totp/keys/#{name}", %{
      generate: false,
      key: key_b32,
      issuer: issuer,
      account_name: account,
      period: 30,
      digits: 6,
      algorithm: "SHA1",
      skew: 1
    })
    |> outcome(:totp_import, name, fn _body -> :ok end)
  end

  defp perform(s, {:totp_validate, name, code}) do
    s.req
    |> request(s.token, :post, "/v1/totp/code/#{name}", %{code: code})
    |> outcome(:totp_validate, name, fn %{"data" => %{"valid" => valid}} -> {:ok, valid} end)
  end

  defp perform(s, {:totp_key, name}) do
    s.req
    |> request(s.token, :get, "/v1/totp/keys/#{name}", nil)
    |> outcome(:totp_key, name, fn %{"data" => data} -> {:ok, data} end)
  end

  defp perform(s, {:totp_delete, name}) do
    s.req
    |> request(s.token, :delete, "/v1/totp/keys/#{name}", nil)
    |> outcome(:totp_delete, name, fn _body -> :ok end)
  end

  defp kv_path(path), do: "/v1/secret/data/" <> path

  defp version_query(nil), do: ""
  defp version_query(version) when is_integer(version) and version > 0, do: "?version=#{version}"

  defp request(req, token, method, url, body) do
    req
    |> Req.merge(method: method, url: url, headers: token_header(token))
    |> with_body(body)
    |> Req.request()
    |> response()
  end

  defp token_header(nil), do: []
  defp token_header(token), do: [{"x-vault-token", token}]

  defp with_body(req, nil), do: req
  defp with_body(req, body), do: Req.merge(req, json: body)

  defp response({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}
  defp response({:ok, %Req.Response{status: 403}}), do: {:error, :forbidden}

  defp response({:ok, %Req.Response{status: status}}) when status in 400..499,
    do: {:error, :invalid}

  defp response({:ok, %Req.Response{status: status}}), do: {:error, {:status, status}}
  defp response({:error, exception}), do: {:error, {:transport, exception}}

  defp outcome({:ok, body}, _op, _path, success), do: success.(body)

  defp outcome({:error, reason}, _op, _path, _success)
       when reason in [:not_found, :forbidden, :invalid],
       do: {:error, reason}

  defp outcome({:error, reason}, op, path, _success) do
    Logger.warning("OpenBao #{op} #{path}: unavailable (#{describe(reason)})")
    {:error, :vault_unavailable}
  end

  # Reasons name what failed, never a value: an exception's message from the
  # transport, a status, a file path.
  defp describe({:transport, exception}), do: Exception.message(exception)
  defp describe({:status, status}), do: "HTTP #{status}"
  defp describe({:bootstrap, path, reason}), do: "#{path}: #{:file.format_error(reason)}"
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
end
