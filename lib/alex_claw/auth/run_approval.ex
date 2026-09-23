defmodule AlexClaw.Auth.RunApproval do
  @moduledoc """
  A person's approval of one run of one workflow.

  A workflow that requires 2FA runs only when the run carries an approval:
  `grant/2` issues one after the caller has verified a second-factor code, and
  the executor consumes it. An approval is opaque (a random token the caller
  cannot construct), bound to a workflow id, valid once, and short-lived.

  Entry points that cannot hold one — schedules, MCP, the cluster trigger, the
  GitHub webhook, SkillAPI — are therefore refused for a protected workflow.

  Approvals live in this process's state, not in a table: there are at most a
  handful at a time, and a restart discarding them only means asking again.
  """
  use GenServer

  @default_ttl_ms 60_000

  @enforce_keys [:token]
  defstruct [:token]

  @type t :: %__MODULE__{token: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Approve one run of `workflow_id`. Call only after a second-factor code for
  that run has been verified. `ttl_ms` (default 60 s) bounds how long it waits.
  """
  @spec grant(integer(), keyword()) :: t()
  def grant(workflow_id, opts \\ []) when is_integer(workflow_id) do
    token = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    expires_at = now() + Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    :ok = GenServer.call(__MODULE__, {:grant, token, workflow_id, expires_at})
    %__MODULE__{token: token}
  end

  @doc """
  Use `approval` for a run of `workflow_id`: `:ok` once for a live approval of
  that workflow, `:error` for anything else. Any attempt uses it up, so an
  approval presented for the wrong workflow cannot be tried again.
  """
  @spec consume(term(), integer()) :: :ok | :error
  def consume(%__MODULE__{token: token}, workflow_id) when is_binary(token),
    do: GenServer.call(__MODULE__, {:consume, token, workflow_id})

  def consume(_not_an_approval, _workflow_id), do: :error

  # --- Server ---

  @impl true
  def init(approvals), do: {:ok, approvals}

  @impl true
  def handle_call({:grant, token, workflow_id, expires_at}, _from, approvals) do
    {:reply, :ok, approvals |> unexpired() |> Map.put(token, {workflow_id, expires_at})}
  end

  def handle_call({:consume, token, workflow_id}, _from, approvals) do
    {entry, rest} = Map.pop(approvals, token)
    {:reply, valid(entry, workflow_id), rest}
  end

  defp valid({workflow_id, expires_at}, workflow_id), do: live(expires_at > now())
  defp valid(_entry, _workflow_id), do: :error

  defp live(true), do: :ok
  defp live(false), do: :error

  defp unexpired(approvals) do
    now = now()
    Map.reject(approvals, fn {_token, {_workflow_id, expires_at}} -> expires_at <= now end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
