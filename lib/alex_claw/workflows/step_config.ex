defmodule AlexClaw.Workflows.StepConfig do
  @moduledoc """
  The one check of a step's config against its skill's contract.

  A skill declares its config fields with `config_schema/0`
  (`%{"field" => %{type: t, required: boolean}}`) and may add rules across
  fields with `validate_config/1`. A skill that declares no schema accepts no
  config keys. Keys starting with `_` are reserved for the runtime: refused
  when a step is saved, allowed when the executor sets them for a run.

  Used when a step is saved (`WorkflowStep.changeset/2`), before each step
  runs (steps saved before the contract existed), and by the tests that hold
  every preset to its skill's own contract. Whether the skill exists and is
  available is checked by the callers, before this.

  Every step may also set the executor's own options, read by the executor
  and not by the skill: `timeout_ms`, `on_circuit_open`, `fallback_skill`,
  `on_missing_skill`.
  """

  @executor_fields %{
    "timeout_ms" => %{type: :integer, required: false},
    "on_circuit_open" => %{type: :string, required: false},
    "fallback_skill" => %{type: :string, required: false},
    "on_missing_skill" => %{type: :string, required: false}
  }

  @doc """
  Check `config` against `skill`'s contract. `:ok`, or `{:error, reasons}`,
  each reason naming the field. Option `runtime: true` allows the keys the
  executor reserves (leading `_`).
  """
  @spec validate(module(), map() | nil, keyword()) :: :ok | {:error, [String.t()]}
  def validate(skill, config, opts \\ []) do
    config = config || %{}
    schema = schema(skill)
    runtime? = Keyword.get(opts, :runtime, false)

    result(
      Enum.flat_map(config, &key_errors(&1, schema, runtime?)) ++
        missing(schema, config) ++ cross_field(skill, config)
    )
  end

  @doc """
  Whether a step for `skill` with `config` can run on this instance: the
  skill's `available?/1` when it declares one (the step's config can make it
  usable, e.g. its own bot token), else `available?/0`, else true.
  """
  @spec available?(module(), map() | nil) :: boolean()
  def available?(skill, config) do
    Code.ensure_loaded(skill)
    availability(skill, config || %{})
  end

  defp availability(skill, config) do
    declared =
      {function_exported?(skill, :available?, 1), function_exported?(skill, :available?, 0)}

    by_declaration(declared, skill, config)
  end

  defp by_declaration({true, _}, skill, config), do: skill.available?(config)
  defp by_declaration({false, true}, skill, _config), do: skill.available?()
  defp by_declaration({false, false}, _skill, _config), do: true

  defp schema(skill) do
    Code.ensure_loaded(skill)
    declared_schema(function_exported?(skill, :config_schema, 0), skill)
  end

  defp declared_schema(true, skill), do: Map.merge(@executor_fields, skill.config_schema())
  defp declared_schema(false, _skill), do: @executor_fields

  defp key_errors({"_" <> _ = key, _value}, _schema, false),
    do: ["#{key}: keys starting with _ are reserved for the runtime"]

  defp key_errors({"_" <> _, _value}, _schema, true), do: []

  defp key_errors({key, value}, schema, _runtime) do
    case Map.fetch(schema, key) do
      {:ok, %{type: type}} -> type_errors(key, value, type)
      :error -> ["#{key}: unknown key"]
    end
  end

  defp type_errors(key, value, type) do
    if of_type?(value, type), do: [], else: ["#{key}: must be #{article(type)} #{type}"]
  end

  defp of_type?(value, :string), do: is_binary(value)
  defp of_type?(value, :integer), do: is_integer(value)
  defp of_type?(value, :number), do: is_number(value)
  defp of_type?(value, :boolean), do: is_boolean(value)
  defp of_type?(value, :map), do: is_map(value)
  defp of_type?(value, :list), do: is_list(value)

  defp article(:integer), do: "an"
  defp article(_type), do: "a"

  defp missing(schema, config) do
    for {key, %{required: true}} <- schema, not Map.has_key?(config, key), do: "#{key}: required"
  end

  defp cross_field(skill, config) do
    if function_exported?(skill, :validate_config, 1),
      do: rule_errors(skill.validate_config(config)),
      else: []
  end

  defp rule_errors(:ok), do: []
  defp rule_errors({:error, reasons}), do: reasons

  defp result([]), do: :ok
  defp result(reasons), do: {:error, reasons}
end
