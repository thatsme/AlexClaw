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
  def label({:provider, id, _type, _host, _api_key, _headers}), do: "provider #{id}"

  defp move({:step, id, workflow_id, skill, config}, opts) do
    with {:ok, config} <- opened(config, StepSecrets.fields(skill, config)) do
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
    with {:ok, api_key} <- Legacy03.decrypt(api_key),
         {:ok, headers} <- Legacy03.decrypt_all(headers) do
      %{["api_key"] => api_key}
      |> Map.merge(Map.new(headers, fn {name, value} -> {["headers", name], value} end))
      |> Map.filter(fn {_path, value} -> value?(value) end)
      |> moved(ProviderSecrets.destination(type, host), "provider", &provider_kind/1, opts)
      |> provider_rewritten(id)
    end
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

  defp rewritten({:ok, plan}, record, sql, id) do
    Repo.query!(sql, [id, Owned.referenced(record, plan)])
    :ok
  end

  defp rewritten(error, _record, _sql, _id), do: error
end
