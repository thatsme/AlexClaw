defmodule AlexClaw.Skill do
  @moduledoc """
  Behaviour for all AlexClaw skills.

  Skills return a triple tuple `{:ok, result, branch}` where branch is an atom
  indicating which outcome occurred (e.g. `:on_items`, `:on_empty`, `:on_error`).
  The legacy `{:ok, result}` format is still supported and treated as `:on_success`.

  Skills declare available branches via the optional `routes/0` callback.
  Default: `[:on_success, :on_error]`.

  A skill also says which of its branches mean failure and which mean
  "nothing to do": `error_routes/0` (default `[:on_error]`) and `empty_routes/0`
  (default `[:on_empty]`). `error_routes/1` and `empty_routes/1` below apply the
  defaults. The executor fails a run on an unrouted error route, marks it
  `recovered` when one is routed, and ends it `completed` on an unrouted empty
  route; so a skill never reports its own failure as success or as "nothing
  found".
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
  # Config keys holding credentials, stored encrypted (AlexClaw.Encrypted.StepConfig).
  # A config key named like a credential must be listed, or the skill is refused.
  @callback secret_config_keys() :: [String.t()]
  @callback prompt_help() :: String.t()
  @doc "Branches that mean the step failed. Default: `[:on_error]`."
  @callback error_routes() :: [atom()]
  @doc "Branches that mean there was nothing to do. Default: `[:on_empty]`."
  @callback empty_routes() :: [atom()]

  @typedoc "A config field's type: what a step's value for it must be."
  @type field_type :: :string | :integer | :number | :boolean | :map | :list
  @typedoc "The config fields a skill accepts, each with its type and whether it is required."
  @type config_schema :: %{String.t() => %{type: field_type(), required: boolean()}}

  @doc "The config fields a step for this skill may set. Any other key is refused."
  @callback config_schema() :: config_schema()
  @doc "Whether the skill can run on this instance (false: not configured)."
  @callback available?() :: boolean()
  @doc "Whether a step with this config can run on this instance; used instead of `available?/0` when declared."
  @callback available?(config :: map()) :: boolean()
  @doc """
  Why a step for this skill cannot be saved, when `available?` is false for a
  reason other than missing configuration. Default: "<skill> is not
  configured on this instance".
  """
  @callback unavailable_reason() :: String.t()
  @doc "Rules across config fields, after each field passed `config_schema/0`."
  @callback validate_config(config :: map()) :: :ok | {:error, [String.t()]}

  @optional_callbacks description: 0,
                      permissions: 0,
                      version: 0,
                      routes: 0,
                      external: 0,
                      step_fields: 0,
                      config_hint: 0,
                      config_scaffold: 0,
                      config_presets: 0,
                      prompt_presets: 0,
                      config_help: 0,
                      secret_config_keys: 0,
                      prompt_help: 0,
                      error_routes: 0,
                      empty_routes: 0,
                      config_schema: 0,
                      available?: 0,
                      available?: 1,
                      unavailable_reason: 0,
                      validate_config: 1

  @doc "`skill`'s error routes, or `[:on_error]` when it declares none."
  @spec error_routes(module()) :: [atom()]
  def error_routes(skill), do: declared(skill, :error_routes, [:on_error])

  @doc "`skill`'s empty routes, or `[:on_empty]` when it declares none."
  @spec empty_routes(module()) :: [atom()]
  def empty_routes(skill), do: declared(skill, :empty_routes, [:on_empty])

  defp declared(skill, callback, default) do
    Code.ensure_loaded(skill)
    declared(function_exported?(skill, callback, 0), skill, callback, default)
  end

  @doc "Why a step for `skill` (named `name`) cannot be saved: its own reason, or that it is not configured."
  @spec unavailable_reason(module(), String.t()) :: String.t()
  def unavailable_reason(skill, name),
    do: declared(skill, :unavailable_reason, "#{name} is not configured on this instance")

  defp declared(true, skill, :error_routes, _default), do: skill.error_routes()
  defp declared(true, skill, :empty_routes, _default), do: skill.empty_routes()
  defp declared(true, skill, :unavailable_reason, _default), do: skill.unavailable_reason()
  defp declared(false, _skill, _callback, default), do: default
end
