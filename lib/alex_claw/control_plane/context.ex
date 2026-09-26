defmodule AlexClaw.ControlPlane.Context do
  @moduledoc """
  Who asks `AlexClaw.ControlPlane.perform/3` for an action, from which entry
  point, and with what proof.

  A context is built from facts, not claims. `admin_ui/1` reads the session's
  elevation; `admin_ui/2` and `gateway/2` carry a code that the control plane
  itself verifies; the other constructors name an entry point that brings no second
  factor. Each constructor seals what it builds: an HMAC over every field,
  under a key made at each start that never leaves the node (`init_key/0`).
  `perform/3` refuses a context whose seal does not match (`verified?/1`) — one
  changed after it was built, by a struct update, or never built by a
  constructor (S8 M5) — and reads the elevation again when the action is
  performed.

  `new/3` states a proof outright. It exists for `authorize/2`'s decision
  alone, which is pure; a context from `new/3` is never performed.

  The session identifier and a code are credentials: they are kept out of
  `inspect/1`, and only the session's fingerprint is ever written anywhere.
  """

  alias AlexClaw.Auth.Elevation

  @type entry_point :: :admin_ui | :gateway | :mcp | :skill | :webhook | :cluster | :system
  @type proof :: :elevation | :code | nil

  @derive {Inspect, except: [:sid, :code, :seal]}
  @enforce_keys [:entry_point, :identity]
  defstruct [:entry_point, :identity, :proof, :sid, :chat_id, :node, :code, :seal]

  @key {__MODULE__, :seal_key}

  @type t :: %__MODULE__{
          entry_point: entry_point(),
          identity: String.t(),
          proof: proof(),
          sid: String.t() | nil,
          chat_id: String.t() | nil,
          node: String.t() | nil,
          code: String.t() | nil,
          seal: binary() | nil
        }

  @doc false
  # Made once at application start, before anything can build a context.
  @spec init_key() :: :ok
  def init_key, do: :persistent_term.put(@key, :crypto.strong_rand_bytes(32))

  @doc "Whether `context` is exactly as one of the constructors built it."
  @spec verified?(t()) :: boolean()
  def verified?(%__MODULE__{seal: seal} = context) when is_binary(seal),
    do: Plug.Crypto.secure_compare(seal, seal_of(context))

  def verified?(%__MODULE__{}), do: false

  defp sealed(%__MODULE__{} = context), do: %{context | seal: seal_of(context)}

  defp seal_of(%__MODULE__{} = c) do
    fields = {c.entry_point, c.identity, c.proof, c.sid, c.chat_id, c.node, c.code}
    :crypto.mac(:hmac, :sha256, :persistent_term.get(@key), :erlang.term_to_binary(fields))
  end

  @doc "A context that states its proof: for `authorize/2` only, never performed."
  @spec new(entry_point(), String.t(), proof()) :: t()
  def new(entry_point, identity, proof),
    do: %__MODULE__{entry_point: entry_point, identity: identity, proof: proof}

  @doc "The admin UI session `sid`, with the elevation it holds now, if any."
  @spec admin_ui(String.t() | nil) :: t()
  def admin_ui(sid) do
    sealed(%__MODULE__{
      entry_point: :admin_ui,
      identity: identity(sid),
      proof: elevation(Elevation.elevated?(sid)),
      sid: sid
    })
  end

  @doc """
  The admin UI session `sid`, offering `code` for an action that needs a
  per-action code. The control plane verifies the code; until then the
  context proves nothing.
  """
  @spec admin_ui(String.t() | nil, String.t()) :: t()
  def admin_ui(sid, code) when is_binary(code),
    do: sealed(%{admin_ui(sid) | proof: nil, code: code})

  @doc "A gateway chat."
  @spec gateway(String.t() | integer()) :: t()
  def gateway(chat_id),
    do: sealed(%{bare(:gateway, "chat:#{chat_id}") | chat_id: to_string(chat_id)})

  @doc """
  A gateway chat answering the challenge it was sent with `code`. The control
  plane checks the code against that chat's challenge; until then the
  context proves nothing.
  """
  @spec gateway(String.t() | integer(), String.t()) :: t()
  def gateway(chat_id, code) when is_binary(code),
    do: sealed(%{gateway(chat_id) | code: code})

  @doc "An MCP client."
  @spec mcp(String.t()) :: t()
  def mcp(client), do: bare(:mcp, "mcp:#{client}")

  @doc "A skill, through SkillAPI."
  @spec skill(String.t()) :: t()
  def skill(name), do: bare(:skill, "skill:#{name}")

  @doc "A webhook."
  @spec webhook(String.t() | integer()) :: t()
  def webhook(id), do: bare(:webhook, "webhook:#{id}")

  @doc """
  Another AlexClaw node asking this one — `node` as the connection reports
  the caller (`AlexClaw.Cluster.Manager` takes it from the calling process),
  never a name the request carries.
  """
  @spec cluster(node() | String.t()) :: t()
  def cluster(node), do: sealed(%{bare(:cluster, "cluster:#{node}") | node: to_string(node)})

  @doc "AlexClaw itself: the scheduler, boot, a migration — named by `reason`."
  @spec system(String.t()) :: t()
  def system(reason), do: bare(:system, "system:#{reason}")

  @doc "Who asked, in the form that may cross into a task (`AlexClaw.ControlPlane.requester/1`)."
  @spec requester(t()) :: AlexClaw.ControlPlane.requester()
  def requester(%__MODULE__{entry_point: :admin_ui, sid: sid}),
    do: AlexClaw.ControlPlane.requester(sid)

  def requester(%__MODULE__{}), do: AlexClaw.ControlPlane.unattended()

  defp bare(entry_point, identity),
    do: sealed(%__MODULE__{entry_point: entry_point, identity: identity})

  defp identity(sid) when is_binary(sid), do: "admin:" <> Elevation.fingerprint(sid)
  defp identity(_sid), do: "admin:unidentified"

  defp elevation(true), do: :elevation
  defp elevation(false), do: nil
end
