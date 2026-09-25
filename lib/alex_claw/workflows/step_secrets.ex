defmodule AlexClaw.Workflows.StepSecrets do
  @moduledoc """
  The credentials in a workflow step's config, kept in OpenBao as secrets the
  step owns (`AlexClaw.Secrets.Owned`); the stored config holds references.

  A step's credential fields are the keys its skill declares secret
  (`c:AlexClaw.Skill.secret_config_keys/0`). A declared key that holds a map
  is a set of headers: only the entries named like a credential are secret
  (`credential_header?/1`), and the others stay as they are. For any other
  map, every entry is secret.

  A `web_automation` step's inline recipe (`steps`, `extra_steps`) has one
  more kind of credential field: each fill's value
  (`AlexClaw.WebAutomation.Recording.fields/1`).

  A step's secrets are bound to where it sends them, as it was when they were
  entered:

    * `telegram_notify`: the Telegram API's host (`:telegram_api_base`);
    * `web_automation`: the origin of the recipe's `url`
      (`origin:<scheme>://<host>[:<port>]`);
    * any other skill: the host of the step's `url`.

  A step with a credential and no such host is refused. At run time the
  executor resolves the references for the same host (`resolved/2`), and the
  skill gets the values; nothing else does.
  """
  alias AlexClaw.Config
  alias AlexClaw.Secrets
  alias AlexClaw.Secrets.Owned
  alias AlexClaw.WebAutomation.Recording
  alias AlexClaw.Workflows.SkillRegistry

  @credential_headers ~w(authorization proxy-authorization cookie x-api-key)
  @credential_pattern ~r/token|key|secret|auth/i

  @doc """
  Whether the header `name` carries a credential: Authorization,
  Proxy-Authorization, Cookie and X-API-Key, and any header whose name
  contains `token`, `key`, `secret` or `auth` (case does not matter).
  """
  @spec credential_header?(String.t()) :: boolean()
  def credential_header?(name) when is_binary(name),
    do: String.downcase(name) in @credential_headers or Regex.match?(@credential_pattern, name)

  @doc "The credential fields of a `skill` step's `config`, as path => value."
  @spec fields(String.t() | nil, map() | nil) :: %{Owned.path() => term()}
  def fields(skill, config) when is_map(config) do
    declared =
      for key <- secret_keys(skill),
          {path, value} <- key_fields(key, Map.get(config, key)),
          into: %{},
          do: {path, value}

    Map.merge(declared, recipe_fields(skill, config))
  end

  def fields(_skill, _config), do: %{}

  defp recipe_fields("web_automation", config), do: Recording.fields(config)
  defp recipe_fields(_skill, _config), do: %{}

  @doc "The secrets a `skill` step's `config` references, as path => name."
  @spec references(String.t() | nil, map() | nil) :: %{Owned.path() => String.t()}
  def references(skill, config), do: skill |> fields(config) |> Owned.references()

  @doc "The destination a `skill` step's credentials are bound to, or nil when it has none."
  @spec destination(String.t() | nil, map() | nil) :: String.t() | nil
  def destination("telegram_notify", _config), do: Config.secret_binding("telegram.bot_token")
  def destination("web_automation", config), do: Recording.destination(config, nil)
  def destination(_skill, config) when is_map(config), do: Owned.url_binding(config["url"])
  def destination(_skill, _config), do: nil

  @doc """
  Plan the credentials of a step being saved from `changeset`, against the
  config it held before (`old_config`, of skill `old_skill`). Returns the
  changeset with the references in place of the values, and what to store
  and delete; or the changeset with an error on `config`.
  """
  @spec plan(Ecto.Changeset.t(), String.t() | nil, map() | nil) ::
          {:ok, Ecto.Changeset.t(), Owned.secrets()} | {:error, Ecto.Changeset.t()}
  def plan(%Ecto.Changeset{valid?: false} = changeset, _old_skill, _old_config),
    do: {:error, changeset}

  def plan(changeset, old_skill, old_config) do
    skill = Ecto.Changeset.get_field(changeset, :skill)
    config = Ecto.Changeset.get_field(changeset, :config) || %{}
    destination = destination(skill, config)
    prefix = "step_#{Ecto.Changeset.get_field(changeset, :workflow_id)}"

    skill
    |> fields(config)
    |> Owned.plan(references(old_skill, old_config), destination, &Owned.name(prefix, &1))
    |> planned(changeset, config, destination)
  end

  defp planned({:ok, plan, dropped}, changeset, config, destination) do
    changeset = Ecto.Changeset.put_change(changeset, :config, Owned.referenced(config, plan))
    {:ok, changeset, {plan, destination, dropped}}
  end

  defp planned({:error, reason}, changeset, _config, _destination),
    do: {:error, Ecto.Changeset.add_error(changeset, :config, reason)}

  @doc "The kind of secret the field at `path` holds."
  @spec kind(Owned.path()) :: String.t()
  def kind(path), do: path |> List.last() |> kind_of()

  defp kind_of("bot_token"), do: "bot_token"
  # A recipe fill's value: a login.
  defp kind_of("value"), do: "login"
  defp kind_of(_field), do: "api_token"

  @doc "Delete every secret the step references."
  @spec delete(%{skill: String.t(), config: map() | nil}) :: :ok
  def delete(%{skill: skill, config: config}),
    do: skill |> references(config) |> Map.values() |> Owned.delete()

  @doc """
  `config` for a copy of the step in workflow `workflow_id`: each secret it
  references copied into a new secret the copy owns, same value and binding.
  """
  @spec copied(String.t(), map() | nil, integer()) :: {:ok, map() | nil} | {:error, term()}
  def copied(skill, config, workflow_id) do
    skill
    |> references(config)
    |> Enum.reduce_while({:ok, config}, fn {path, name}, {:ok, acc} ->
      new = Owned.name("step_#{workflow_id}", path)

      case Owned.copy(name, new) do
        :ok -> {:cont, {:ok, Owned.put(acc, path, Owned.reference(new))}}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  `config` with each reference replaced by its value, resolved for the step's
  destination: what the executor hands the skill. Every use is audited.
  """
  @spec resolved(String.t(), map() | nil) :: {:ok, map() | nil} | {:error, term()}
  def resolved(skill, config) do
    skill
    |> references(config)
    |> Enum.reduce_while({:ok, config}, fn {path, name}, {:ok, acc} ->
      case resolve(name, destination(skill, config)) do
        {:ok, value} -> {:cont, {:ok, Owned.put(acc, path, value)}}
        {:error, reason} -> {:halt, {:error, {:secret, List.last(path), reason}}}
      end
    end)
  end

  defp resolve(_name, nil), do: {:error, :no_destination}
  defp resolve(name, destination), do: Secrets.resolve(name, for: destination)

  defp secret_keys(skill) when is_binary(skill) do
    case SkillRegistry.resolve(skill) do
      {:ok, module} -> declared_keys(module)
      {:error, _reason} -> []
    end
  end

  defp secret_keys(_skill), do: []

  defp declared_keys(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :secret_config_keys, 0),
      do: module.secret_config_keys(),
      else: []
  end

  defp key_fields(_key, nil), do: []

  defp key_fields(key, value) when is_map(value) do
    if Owned.reference?(value),
      do: [{[key], value}],
      else: for({entry, v} <- value, entry_secret?(key, entry), do: {[key, entry], v})
  end

  defp key_fields(key, value), do: [{[key], value}]

  defp entry_secret?("headers", name), do: credential_header?(name)
  defp entry_secret?(_key, _name), do: true
end
