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

  # UI metadata — declares how the step editor renders for this skill
  @callback step_fields() :: [atom()]
  @callback config_hint() :: String.t()
  @callback config_scaffold() :: map()
  @callback config_presets() :: %{String.t() => map()}
  @callback prompt_presets() :: %{String.t() => String.t()}
  @callback config_help() :: String.t()
  @callback prompt_help() :: String.t()

  @optional_callbacks description: 0, permissions: 0, version: 0, routes: 0, external: 0,
                      step_fields: 0, config_hint: 0, config_scaffold: 0, config_presets: 0,
                      prompt_presets: 0, config_help: 0, prompt_help: 0
end
