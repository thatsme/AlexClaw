defmodule AlexClaw.LLM.LocalLock do
  @moduledoc """
  One call to a local model at a time.

  A local model server holds its weights in the host's memory and answers one
  prompt at a time anyway; several callers only queue inside it, each holding
  its own context. Two runs at once — a skill generation and a reasoning
  session — kept both model servers loaded until the host froze.

  A second local call is refused with `{:error, :local_model_busy}` rather than
  queued: the caller learns at once, instead of waiting behind work it cannot
  see. Embeddings are not held here; they are small and constant.
  """
  alias AlexClaw.Lock

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: Lock.child_spec(name: __MODULE__, busy: :local_model_busy)

  @doc "Take the local-call lock for `owner`."
  @spec acquire(pid()) :: :ok | {:error, :local_model_busy}
  def acquire(owner \\ self()), do: Lock.acquire(__MODULE__, owner)

  @doc "Release the lock if `owner` holds it."
  @spec release(pid()) :: :ok
  def release(owner \\ self()), do: Lock.release(__MODULE__, owner)

  @doc "Run `fun` holding the lock, or refuse with `{:error, :local_model_busy}`."
  @spec run((-> result)) :: result | {:error, :local_model_busy} when result: term()
  def run(fun), do: Lock.run(__MODULE__, fun)
end
