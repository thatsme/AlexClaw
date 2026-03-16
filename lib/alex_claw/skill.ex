defmodule AlexClaw.Skill do
  @moduledoc """
  Behaviour for all AlexClaw skills.
  """
  @callback run(args :: map()) :: {:ok, result :: any()} | {:error, reason :: any()}
  @callback description() :: String.t()

  @optional_callbacks description: 0
end
