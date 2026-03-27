defmodule AlexClaw.Skill do
  @moduledoc """
  Behaviour for all AlexClaw skills.

  Skills return a triple tuple `{:ok, result, branch}` where branch is an atom
  indicating which outcome occurred (e.g. `:on_items`, `:on_empty`, `:on_error`).
  The legacy `{:ok, result}` format is still supported and treated as `:on_success`.

  Skills declare available branches via the optional `routes/0` callback.
  Default: `[:on_success, :on_error]`.
  """
  @callback run(args :: map()) ::
              {:ok, result :: any(), branch :: atom()}
              | {:ok, result :: any()}
              | {:error, reason :: any()}
  @callback description() :: String.t()
  @callback permissions() :: [atom()]
  @callback version() :: String.t()
  @callback routes() :: [atom()]
  @callback external() :: boolean()

  @optional_callbacks description: 0, permissions: 0, version: 0, routes: 0, external: 0
end
