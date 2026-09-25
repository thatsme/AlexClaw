defmodule AlexClaw.Config.SecretUpgrade.Records do
  @moduledoc """
  The part of `AlexClaw.Config.SecretUpgrade` for records: the credentials a
  0.3.x step config or resource still holds as values move to OpenBao, as
  secrets the record owns (`AlexClaw.Secrets.Owned`), and the record keeps
  references.

  For each record, in this order: every credential value is read (decrypted
  where 0.3.x encrypted it), stored in OpenBao bound to the record's host,
  READ BACK and compared; only then is the row rewritten with references. Any
  failure — no host to bind to, OpenBao refusing, a read-back that differs —
  leaves the row exactly as it was, deletes what was stored for it, is
  reported by the record, and is tried again at the next start.
  """
  alias AlexClaw.{Encrypted, Repo, Secrets}
  alias AlexClaw.Resources.ResourceSecrets
  alias AlexClaw.Secrets.Owned
  alias AlexClaw.WebAutomation.Recording
  alias AlexClaw.Workflows.StepSecrets

  @typedoc "A record with credential values to move."
  @type pending ::
          {:step, integer(), integer(), String.t(), map()}
          | {:resource, integer(), String.t(), map()}

  @doc "Every step and resource still holding a credential value."
  @spec pending() :: [pending()]
  def pending, do: pending_steps() ++ pending_resources()

  defp pending_steps do
    %{rows: rows} =
      Repo.query!("SELECT id, workflow_id, skill, config FROM workflow_steps ORDER BY id")

    for [id, workflow_id, skill, config] <- rows,
        values?(StepSecrets.fields(skill, config)),
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

  defp move({:step, id, workflow_id, skill, config}, opts) do
    config = opened(config, StepSecrets.fields(skill, config))

    config
    |> values(StepSecrets.fields(skill, config))
    |> moved(
      StepSecrets.destination(skill, config),
      "step_#{workflow_id}",
      &StepSecrets.kind/1,
      opts
    )
    |> rewritten(config, "UPDATE workflow_steps SET config = $2 WHERE id = $1", id)
  end

  # Its credential is bound to the resource's host, a recording's logins to its
  # origin: two plans, one rewrite of the row.
  defp move({:resource, id, url, metadata}, opts) do
    metadata
    |> resource_parts(url)
    |> moved_parts(metadata, opts)
    |> rewritten(metadata, "UPDATE resources SET metadata = $2 WHERE id = $1", id)
  end

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
  # also held the headers that are not credentials).
  defp opened(config, fields) do
    keys = fields |> Map.keys() |> Enum.map(&hd/1) |> Enum.uniq()
    Enum.reduce(keys, config, fn key, acc -> Map.update!(acc, key, &open/1) end)
  end

  defp open(value) when is_map(value) do
    if Owned.reference?(value), do: value, else: Map.new(value, fn {k, v} -> {k, open(v)} end)
  end

  defp open(value) when is_list(value), do: Enum.map(value, &open/1)
  defp open("enc:" <> _ = value), do: Encrypted.open!(value)
  defp open(value), do: value

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

  defp moved(values, destination, prefix, kind, opts) do
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

  defp rewritten({:ok, plan}, record, sql, id) do
    Repo.query!(sql, [id, Owned.referenced(record, plan)])
    :ok
  end

  defp rewritten(error, _record, _sql, _id), do: error
end
