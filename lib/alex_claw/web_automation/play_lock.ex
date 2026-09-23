defmodule AlexClaw.WebAutomation.PlayLock do
  @moduledoc """
  One web-automation play at a time.

  The sidecar runs one play at a time and answers a second with 409; holding
  this lock around a play means AlexClaw refuses the second itself, with
  `{:error, :busy}`, before any request. Refused, not queued: a queued play
  would only run later against a page the caller no longer waits for.
  """

  alias AlexClaw.Lock

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: Lock.child_spec(name: __MODULE__, busy: :busy)

  @doc "Run `fun` holding the lock, or return `{:error, :busy}`."
  @spec run((-> result)) :: result | {:error, :busy} when result: term()
  def run(fun), do: Lock.run(__MODULE__, fun)
end
