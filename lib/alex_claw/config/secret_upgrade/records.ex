defmodule AlexClaw.Config.SecretUpgrade.Records do
  @moduledoc """
  The part of `AlexClaw.Config.SecretUpgrade` for records: the credentials a
  0.3.x step config, resource or LLM provider still holds as values move to
  OpenBao, as secrets the record owns (`AlexClaw.Secrets.Owned`), and the
  record keeps references. A provider's sealed `api_key` and `headers`
  columns, which the schema no longer maps, are emptied once its
  `credentials` hold the references (0.4.0 S7).

  For each record, in this order: every credential value is read (decrypted
  where 0.3.x encrypted it), stored in OpenBao bound to the record's host,
  READ BACK and compared; only then is the row rewritten with references. Any
  failure — no host to bind to, OpenBao refusing, a read-back that differs —
  leaves the row exactly as it was, deletes what was stored for it, is
  reported by the record, and is tried again at the next start.
  """
  require Logger

  alias AlexClaw.LLM.ProviderSecrets
  alias AlexClaw.{Repo, Secrets}
  alias AlexClaw.Resources.ResourceSecrets
  alias AlexClaw.Secrets.Owned
  alias AlexClaw.Upgrade.Legacy03
  alias AlexClaw.WebAutomation.Recording
  alias AlexClaw.Workflows.StepSecrets

  @typedoc "A record with credential values to move."
  @type pending ::
          {:step, integer(), integer(), String.t(), map()}
          | {:resource, integer(), String.t(), map()}
          | {:provider, integer(), String.t(), String.t() | nil, String.t() | nil, map()}

  @doc "Every step, resource and LLM provider still holding a credential value."
  @spec pending() :: [pending()]
  def pending, do: pending_steps() ++ pending_resources() ++ pending_providers()

  # The columns the schema no longer maps: what 0.3.x stored, sealed.
  defp pending_providers do
    %{rows: rows} =
      Repo.query!("SELECT id, type, host, api_key, headers FROM llm_providers ORDER BY id")

    for [id, type, host, api_key, headers] <- rows,
        value?(api_key) or (is_map(headers) and headers != %{}),
        do: {:provider, id, type, host, api_key, headers || %{}}
  end

  defp pending_steps do
    %{rows: rows} =
      Repo.query!("SELECT id, workflow_id, skill, config FROM workflow_steps ORDER BY id")

    for [id, workflow_id, skill, config] <- rows,
        values?(StepSecrets.fields(skill, config)) or sealed_paths(config, []) != [],
        do: {:step, id, workflow_id, skill, config}
  end

  defp pending_resources do
    %{rows: rows} = Repo.query!("SELECT id, url, metadata FROM resources ORDER BY id")

    for [id, url, metadata] <- rows,
        values?(resource_fields(metadata)),
        do: {:resource, id, url, metadata}
  end

  # A resource's credential, and a recording's fill values: the recorder never
  # noted field types, so every recorded fill value is treated as a login.
  defp resource_fields(metadata),
    do: Map.merge(ResourceSecrets.fields(metadata), Recording.fields(metadata))

  defp values?(fields), do: Enum.any?(fields, fn {_path, value} -> value?(value) end)

  defp value?(value) when value in [nil, ""], do: false
  defp value?(value), do: not Owned.reference?(value)

  @doc """
  Move each pending record. Returns the records moved and those not, with
  why, each named like `"step 12"` or `"resource 3"`.
  """
  @spec move_all([pending()], keyword()) :: %{moved: [String.t()], failed: [{String.t(), term()}]}
  def move_all(pending, opts) do
    results = Enum.map(pending, &{label(&1), move(&1, opts)})

    %{
      moved: for({label, :ok} <- results, do: label),
      failed: for({label, {:error, reason}} <- results, do: {label, reason})
    }
  end

  @doc "How a pending record is named in the upgrade's report."
  @spec label(pending()) :: String.t()
  def label({:step, id, _workflow_id, _skill, _config}), do: "step #{id}"
  def label({:resource, id, _url, _metadata}), do: "resource #{id}"
  def label({:provider, id, _type, _host, _api_key, _headers}), do: "provider #{id}"

  # The skill's credentials move as its credentials; anything else 0.3.x left
  # sealed in the config is parked (S8 M1).
  defp move({:step, id, workflow_id, skill, config}, opts) do
    fields = StepSecrets.fields(skill, config)
    destination = StepSecrets.destination(skill, config)

    with {:ok, config} <- opened(config, fields),
         {:ok, plan} <-
           config
           |> values(fields)
           |> moved_if_any(destination, "step_#{workflow_id}", &StepSecrets.kind/1, opts) do
      config
      |> Owned.referenced(plan)
      |> parked_sealed("parked_step_#{id}", opts)
      |> undone_unless_parked(plan)
      |> rewritten(%{}, "UPDATE workflow_steps SET config = $2 WHERE id = $1", id)
    end
  end

  # Its credential is bound to the resource's host, a recording's logins to its
  # origin: two plans, one rewrite of the row.
  defp move({:resource, id, url, metadata}, opts) do
    metadata
    |> resource_parts(url)
    |> moved_parts(metadata, opts)
    |> rewritten(metadata, "UPDATE resources SET metadata = $2 WHERE id = $1", id)
  end

  # The key and every header value, each bound to the provider's host; the row
  # gets references in `credentials`, and the legacy columns are emptied.
  defp move({:provider, id, type, host, api_key, headers}, opts) do
    with :ok <- not_reentered(id),
         {:ok, api_key} <- Legacy03.decrypt(api_key),
         {:ok, headers} <- Legacy03.decrypt_all(headers) do
      %{["api_key"] => api_key}
      |> Map.merge(Map.new(headers, fn {name, value} -> {["headers", name], value} end))
      |> Map.filter(fn {_path, value} -> value?(value) end)
      |> moved(ProviderSecrets.destination(type, host), "provider", &provider_kind/1, opts)
      |> provider_rewritten(id)
    end
  end

  # Credentials entered in 0.4.0 (after a first start that could not reach
  # OpenBao) are kept: the 0.3.x key is not moved over them (S8 H6). Its
  # columns stay as they were, and the conflict is reported.
  defp not_reentered(id) do
    %{rows: [[credentials]]} =
      Repo.query!("SELECT credentials FROM llm_providers WHERE id = $1", [id])

    credentials
    |> ProviderSecrets.references()
    |> Map.values()
    |> reentered()
  end

  defp reentered([]), do: :ok
  defp reentered(names), do: {:error, {:conflict, Enum.join(Enum.sort(names), ", ")}}

  defp resource_parts(metadata, url) do
    [
      {ResourceSecrets.fields(metadata), ResourceSecrets.destination(url, metadata), "resource",
       &ResourceSecrets.kind/1},
      {Recording.fields(metadata), Recording.destination(metadata, url), "recording",
       fn _path -> "login" end}
    ]
    |> Enum.reject(fn {fields, _destination, _prefix, _kind} ->
      values(metadata, fields) == %{}
    end)
  end

  defp moved_parts(parts, metadata, opts) do
    Enum.reduce_while(parts, {:ok, %{}}, fn part, {:ok, plan} ->
      part |> moved_part(metadata, opts) |> part_moved(plan)
    end)
  end

  defp moved_part({fields, destination, prefix, kind}, metadata, opts),
    do: moved(values(metadata, fields), destination, prefix, kind, opts)

  defp part_moved({:ok, part}, plan), do: {:cont, {:ok, Map.merge(plan, part)}}
  defp part_moved(error, plan), do: {:halt, undone(error, plan)}

  # A later part failed: what the earlier parts stored is deleted too.
  defp undone(error, plan) do
    plan |> Enum.map(fn {_path, {:store, name, _value}} -> name end) |> Owned.delete()
    error
  end

  # Every sealed string in a credential field, decrypted (a sealed header map
  # also held the headers that are not credentials). A value that does not
  # decrypt stops this record: it is reported, and the row left as it was.
  defp opened(config, fields) do
    fields
    |> Map.keys()
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, config}, fn key, {:ok, acc} ->
      acc |> Map.fetch!(key) |> Legacy03.decrypt_all() |> opened_key(key, acc)
    end)
  end

  defp opened_key({:ok, value}, key, acc), do: {:cont, {:ok, Map.put(acc, key, value)}}
  defp opened_key(error, _key, _acc), do: {:halt, error}

  defp values(record, fields),
    do:
      for(
        {path, _} <- fields,
        value = Owned.get(record, path),
        value?(value),
        into: %{},
        do: {path, value}
      )

  defp moved(_values, nil, _prefix, _kind, _opts), do: {:error, :no_destination}

  # 0.3.x kept whatever JSON a field held (S8 M12): a number or a boolean is
  # carried over as its text; a list or an object cannot be one credential,
  # and its record is reported and left as it was.
  defp moved(values, destination, prefix, kind, opts) do
    texts = Map.new(values, fn {path, value} -> {path, as_text(value)} end)
    with :ok <- all_text(texts), do: move_values(texts, destination, prefix, kind, opts)
  end

  defp as_text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp as_text(value), do: value

  defp all_text(values) do
    values
    |> Enum.find(fn {_path, value} -> not is_binary(value) end)
    |> text_or_field()
  end

  defp text_or_field(nil), do: :ok
  defp text_or_field({path, _value}), do: {:error, {:not_text, List.last(path)}}

  defp move_values(values, destination, prefix, kind, opts) do
    plan =
      Map.new(values, fn {path, value} -> {path, {:store, Owned.name(prefix, path), value}} end)

    with :ok <- stored(plan, destination, kind, opts),
         :ok <- read_back(plan, opts) do
      {:ok, plan}
    else
      error ->
        plan |> Enum.map(fn {_path, {:store, name, _value}} -> name end) |> Owned.delete()
        error
    end
  end

  defp stored(plan, destination, kind, opts) do
    Enum.reduce_while(plan, :ok, fn {path, {:store, name, value}}, :ok ->
      with :ok <- defined(Secrets.get(name), name, kind.(path), destination),
           :ok <- Secrets.put_value(name, value, opts) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp defined(nil, name, kind, destination) do
    case Secrets.define(%{name: name, kind: kind, binding: [destination]}) do
      {:ok, _secret} -> :ok
      {:error, _changeset} -> {:error, :not_catalogued}
    end
  end

  defp defined(_secret, _name, _kind, _destination), do: :ok

  defp read_back(plan, opts) do
    Enum.reduce_while(plan, :ok, fn {_path, {:store, name, value}}, :ok ->
      case Secrets.value_matches?(name, value, opts) do
        true -> {:cont, :ok}
        false -> {:halt, {:error, :read_back_differs}}
        {:error, reason} -> {:halt, {:error, {:read_back, reason}}}
      end
    end)
  end

  defp provider_kind(["api_key"]), do: "api_token"
  defp provider_kind(_header), do: "other"

  defp provider_rewritten({:ok, plan}, id) do
    Repo.query!(
      "UPDATE llm_providers SET credentials = $2, api_key = NULL, headers = '{}' WHERE id = $1",
      [id, Owned.referenced(%{"headers" => %{}}, plan)]
    )

    :ok
  end

  defp provider_rewritten(error, _id), do: error

  defp moved_if_any(values, _destination, _prefix, _kind, _opts) when values == %{},
    do: {:ok, %{}}

  defp moved_if_any(values, destination, prefix, kind, opts),
    do: moved(values, destination, prefix, kind, opts)

  # --- What 0.3.x sealed outside the skill's credentials (S8 M1) ---

  # 0.3.x sealed every key any skill declared secret, in every step. Such a
  # value is not this skill's credential: like a custom sensitive setting it
  # goes to OpenBao bound to nothing it can be sent to, its field is emptied,
  # and it is named in the log, to be declared or deleted.
  @parked "inbound:carried_over"

  defp parked_sealed(config, prefix, opts) do
    config
    |> sealed_paths([])
    |> Enum.reduce_while({:ok, config, []}, fn {path, sealed}, {:ok, acc, names} ->
      path |> parked_one(sealed, prefix, opts) |> parked_into(path, acc, names)
    end)
  end

  defp parked_one(path, sealed, prefix, opts) do
    name = Owned.name(prefix, path)

    with {:ok, value} <- Legacy03.decrypt(sealed),
         {:ok, _secret} <- define_parked(name, path),
         :ok <- Secrets.put_value(name, value, opts) do
      {:ok, name}
    end
  end

  defp define_parked(name, path),
    do:
      Secrets.define(%{
        name: name,
        kind: "other",
        binding: [@parked],
        description:
          "#{Enum.join(path, ".")} of a step, carried over by the 0.4.0 upgrade: declare it or delete it"
      })

  defp parked_into({:ok, name}, path, config, names),
    do: {:cont, {:ok, Owned.put(config, path, ""), [name | names]}}

  defp parked_into(error, _path, _config, names) do
    Owned.delete(names)
    {:halt, error}
  end

  defp undone_unless_parked({:ok, config, names}, _plan) do
    Enum.each(names, fn name ->
      Logger.warning(
        "A step held a value 0.3.x stored encrypted outside its skill's credentials; " <>
          "it is now the OpenBao secret #{name}, sent nowhere. Declare it or delete it."
      )
    end)

    {:ok, {:config, config}}
  end

  defp undone_unless_parked(error, plan) do
    plan |> Enum.map(fn {_path, {:store, name, _value}} -> name end) |> Owned.delete()
    error
  end

  defp sealed_paths("enc:" <> _ = sealed, path), do: [{Enum.reverse(path), sealed}]

  defp sealed_paths(map, path) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> sealed_paths(value, [key | path]) end)

  defp sealed_paths(list, path) when is_list(list),
    do: list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> sealed_paths(v, [i | path]) end)

  defp sealed_paths(_value, _path), do: []

  defp rewritten({:ok, {:config, config}}, _record, sql, id) do
    Repo.query!(sql, [id, config])
    :ok
  end

  defp rewritten({:ok, plan}, record, sql, id) do
    Repo.query!(sql, [id, Owned.referenced(record, plan)])
    :ok
  end

  defp rewritten(error, _record, _sql, _id), do: error
end
