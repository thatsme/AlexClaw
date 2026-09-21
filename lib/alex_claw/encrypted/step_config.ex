defmodule AlexClaw.Encrypted.StepConfig do
  @moduledoc """
  A workflow step's `config`, with the keys any skill declares secret
  (`c:AlexClaw.Skill.secret_config_keys/0`) stored encrypted. The type does not
  know which skill a step runs, so a declared key is encrypted, and decrypted,
  in every step's config; other keys are left as they are. See
  `AlexClaw.Encrypted`.
  """

  use Ecto.Type

  alias AlexClaw.Encrypted
  alias AlexClaw.Workflows.SkillRegistry

  @impl true
  def type, do: :map

  @impl true
  def cast(value) when is_map(value) or is_nil(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}

  def dump(value) when is_map(value), do: {:ok, map_secrets(value, &Encrypted.seal/1)}

  def dump(_value), do: :error

  @impl true
  def load(nil), do: {:ok, nil}
  def load(value) when is_map(value), do: {:ok, map_secrets(value, &Encrypted.open!/1)}
  def load(_value), do: :error

  defp map_secrets(config, fun) do
    secret = SkillRegistry.secret_config_keys()
    Map.new(config, fn {k, v} -> {k, apply_if(to_string(k) in secret, fun, v)} end)
  end

  defp apply_if(true, fun, value), do: fun.(value)
  defp apply_if(false, _fun, value), do: value
end
