defmodule AlexClaw.LLM.Behaviour do
  @moduledoc """
  Contract for the LLM facade. Production code uses `AlexClaw.LLM.Real`;
  tests can swap a Mox mock at the single dispatch seam in `AlexClaw.LLM`.
  """

  @callback complete(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback embed(text :: String.t(), opts :: keyword()) ::
              {:ok, list(float())} | {:error, term()}
end
