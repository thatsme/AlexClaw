defmodule AlexClawTest.LLMMock do
  @moduledoc """
  One way for a test to stand the LLM in with `AlexClaw.LLM.Mock`, and the
  failures a real provider produces.

  Four test files each had their own swap-and-restore helper, and no stub
  could return a timeout — so no skill was ever tested against the failure
  that ended run 20 (2026-09-23): a local model timing out.

      setup :use_mock
      ...
      LLMMock.fail_with(LLMMock.timeout())

  `use_mock/1` swaps the mock in globally (Mox global mode: skills call the
  model from tasks), and restores the previous implementation on exit.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Swap AlexClaw.LLM.Mock in for this test; restored on exit."
  def use_mock(_context \\ %{}) do
    previous = Application.get_env(:alex_claw, :llm_impl)
    Application.put_env(:alex_claw, :llm_impl, AlexClaw.LLM.Mock)
    Mox.set_mox_global()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:alex_claw, :llm_impl, previous),
        else: Application.delete_env(:alex_claw, :llm_impl)
    end)

    :ok
  end

  @doc "What the router returns when a local model runs out of time."
  def timeout, do: {:error, {:ollama, %Req.TransportError{reason: :timeout}}}

  @doc "What the router returns when no provider can take the call."
  def unavailable, do: {:error, :no_available_model}

  @doc "Every completion returns `result`."
  def fail_with(result) do
    Mox.stub(AlexClaw.LLM.Mock, :complete, fn _prompt, _opts -> result end)
    Mox.stub(AlexClaw.LLM.Mock, :complete_fitted, fn _builder, _opts -> result end)
  end

  @doc "Every completion answers `text`."
  def answer(text), do: fail_with({:ok, text})

  @doc """
  An empty knowledge base: embeddings succeed (zero vectors), so a search
  finds nothing. For skills that search before they generate (coder).
  """
  def no_knowledge(dimensions \\ 768) do
    Mox.stub(AlexClaw.LLM.Mock, :embed, fn _text, _opts ->
      {:ok, List.duplicate(0.0, dimensions)}
    end)
  end
end
