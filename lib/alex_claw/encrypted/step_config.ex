defmodule AlexClaw.Encrypted.StepConfig do
  @moduledoc """
  A workflow step's `config`.

  Since 0.4.0 a step's credentials are not in its config at all: it holds
  references to secrets in OpenBao (`AlexClaw.Workflows.StepSecrets`), so
  nothing is encrypted on the way in. A config written by 0.3.x still holds
  its declared secret keys (`c:AlexClaw.Skill.secret_config_keys/0`)
  encrypted, until `AlexClaw.Config.SecretUpgrade` moves them; those are
  decrypted on the way out. The type does not know which skill a step runs, so
  a declared key is decrypted in every step's config. See `AlexClaw.Encrypted`.
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

  def dump(value) when is_map(value), do: {:ok, value}

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
