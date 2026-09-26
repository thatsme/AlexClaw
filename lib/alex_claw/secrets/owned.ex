defmodule AlexClaw.Secrets.Owned do
  @moduledoc """
  Secrets that belong to a record, such as a workflow step's credential fields
  or a resource's auth value. They are kept in OpenBao; the record holds only a
  reference, `%{"secret" => name}`.

  Unlike a secret setting, an owned secret is bound to one destination, fixed
  when its value is entered. Saving a record plans each of its credential
  fields against the references it held before:

    * a reference the record already held is kept, as long as the destination
      has not moved; a different destination with the old credential is
      refused: moving a credential is always a deliberate re-entry;
    * a new value is stored under the field's existing name (bound, or bound
      again, to the destination) or under a new one;
    * an empty value clears the field;
    * a reference the record did not hold is refused: a record cannot borrow
      another one's secret.

  The secrets a save no longer references are deleted once it has committed.
  """
  alias AlexClaw.{Repo, Secrets}

  @typedoc "Where a field is in a record: map keys, and list indices (a recipe's steps)."
  @type path :: [String.t() | non_neg_integer()]
  @type action :: {:keep, String.t()} | {:store, String.t(), String.t()}
  @type plan :: %{path() => action()}
  @type namer :: (path() -> String.t())
  @typedoc """
  Where a plan's values are bound: one destination, or one per path (a
  resource's credential is bound to a host, its recording's logins to an
  origin).
  """
  @type destination :: String.t() | nil | (path() -> String.t() | nil)
  @typedoc "A planned save: the plan, the destination, the names no longer referenced."
  @type secrets :: {plan(), destination(), [String.t()]}

  @placeholder_whole ~r/\A\{\{secret:([a-z0-9_]{2,64})\}\}\z/

  @doc "A reference to the secret `name`, as a record stores it."
  @spec reference(String.t()) :: map()
  def reference(name), do: %{"secret" => name}

  @doc "Whether `value` is a reference to a secret."
  @spec reference?(term()) :: boolean()
  def reference?(%{"secret" => name}) when is_binary(name), do: true
  def reference?(_value), do: false

  @doc "The references among `fields` (path => value), as path => secret name."
  @spec references(%{path() => term()}) :: %{path() => String.t()}
  def references(fields),
    do:
      for(
        {path, %{"secret" => name} = value} <- fields,
        reference?(value),
        into: %{},
        do: {path, name}
      )

  @doc """
  The secrets among `fields` as a skill was given them — a placeholder
  (`placeholder/1`) standing alone as a field's value — as path => secret
  name. Only for what a run hands over: a stored record holds references
  (`references/1`), never placeholders.
  """
  @spec given(%{path() => term()}) :: %{path() => String.t()}
  def given(fields) do
    fields
    |> Enum.flat_map(fn {path, value} -> value |> placeholder_name() |> named(path) end)
    |> Map.new()
  end

  defp named(nil, _path), do: []
  defp named(name, path), do: [{path, name}]

  @doc """
  The secret name `value` stands for when it is a placeholder standing alone
  (`placeholder/1`), else nil. A placeholder inside other text stands for
  nothing: it is never filled (`AlexClaw.Net.Credentials`).
  """
  @spec placeholder_name(term()) :: String.t() | nil
  def placeholder_name("{{secret:" <> _ = value),
    do: whole_placeholder(Regex.run(@placeholder_whole, value))

  def placeholder_name(_value), do: nil

  defp whole_placeholder([_whole, name]), do: name
  defp whole_placeholder(nil), do: nil

  @doc """
  What a skill is given for the secret `name`: `{{secret:NAME}}`. It stands
  for the value in a declared slot only — a header the HTTP layer fills at
  send (`AlexClaw.Net.Credentials`); the skill never holds the value.
  """
  @spec placeholder(String.t()) :: String.t()
  def placeholder(name), do: "{{secret:" <> name <> "}}"

  @doc """
  `record` with each reference among `fields` replaced by its placeholder, and
  the names — what a skill is given: never a value.
  """
  @spec with_placeholders(map(), %{path() => term()}) :: {map(), [String.t()]}
  def with_placeholders(record, fields) do
    refs = references(fields)

    {Enum.reduce(refs, record, fn {path, name}, acc -> put(acc, path, placeholder(name)) end),
     Map.values(refs)}
  end

  @doc """
  `:ok` when every credential field holds a reference or nothing; else
  `{:error, path}` for the first that still holds a value — one 0.3.x left
  that the boot upgrade has not moved yet. Such a value is never used: since
  0.4.0 (S7) nothing decrypts it, and it never went through a binding.
  """
  @spec all_moved(%{path() => term()}) :: :ok | {:error, path()}
  def all_moved(fields) do
    fields
    |> Enum.find(fn {_path, value} -> value not in [nil, ""] and not reference?(value) end)
    |> moved()
  end

  defp moved(nil), do: :ok
  defp moved({path, _value}), do: {:error, path}

  @doc """
  Plan the save of the credential `fields` (path => value in the record being
  saved) against `old` (path => the secret it referenced), for `destination`.
  `new_name` names the secret of a field that had none. Returns the plan and
  the names no longer referenced, or a reason to refuse the save.
  """
  @spec plan(%{path() => term()}, %{path() => String.t()}, String.t() | nil, namer()) ::
          {:ok, plan(), [String.t()]} | {:error, String.t()}
  def plan(fields, old, destination, new_name) do
    fields
    |> Enum.reduce_while({:ok, %{}}, fn {path, value}, {:ok, plan} ->
      path
      |> action(value, Map.get(old, path), destination, new_name)
      |> planned(path, plan)
    end)
    |> with_dropped(old)
  end

  defp planned({:ok, nil}, _path, plan), do: {:cont, {:ok, plan}}
  defp planned({:ok, action}, path, plan), do: {:cont, {:ok, Map.put(plan, path, action)}}
  defp planned({:error, _reason} = error, _path, _plan), do: {:halt, error}

  defp with_dropped({:ok, plan}, old) do
    kept = for {_path, action} <- plan, do: elem(action, 1)
    {:ok, plan, Map.values(old) -- kept}
  end

  defp with_dropped(error, _old), do: error

  defp action(_path, value, _old, _destination, _new_name) when value in [nil, ""], do: {:ok, nil}

  defp action(_path, %{"secret" => name}, name, destination, _new_name),
    do: kept(Secrets.get(name), name, destination)

  defp action(_path, %{"secret" => _other}, _old, _destination, _new_name),
    do: {:error, "a credential reference cannot be set here; enter the credential itself"}

  defp action(_path, value, _old, nil, _new_name) when is_binary(value),
    do: {:error, "a credential needs a destination host to be bound to: give a full URL"}

  defp action(path, value, old, _destination, new_name) when is_binary(value),
    do: {:ok, {:store, old || new_name.(path), value}}

  defp action(_path, _value, _old, _destination, _new_name),
    do: {:error, "a credential must be text"}

  defp kept(nil, _name, _destination),
    do: {:error, "the stored credential is missing; enter it again"}

  defp kept(%{binding: [destination]}, name, destination), do: {:ok, {:keep, name}}

  defp kept(_secret, _name, _destination),
    do: {:error, "the credential must be re-entered for the new host"}

  @doc "`record` (a map) with each planned field replaced by its reference."
  @spec referenced(map(), plan()) :: map()
  def referenced(record, plan),
    do:
      Enum.reduce(plan, record, fn {path, action}, acc ->
        put(acc, path, reference(elem(action, 1)))
      end)

  @doc "The value at `path` in `record`."
  @spec get(map(), path()) :: term()
  def get(record, path), do: get_in(record, access(path))

  @doc "`record` with `value` at `path`."
  @spec put(map(), path(), term()) :: map()
  def put(record, path, value), do: put_in(record, access(path), value)

  defp access(path), do: Enum.map(path, &access_key/1)

  defp access_key(index) when is_integer(index), do: Access.at(index)
  defp access_key(key), do: key

  @doc """
  Store the plan's new values in OpenBao, each bound to `destination`: a
  secret is catalogued on first use, and bound again when it was bound
  elsewhere. `kind` gives each path's kind of secret.
  """
  @spec store_all(plan(), destination(), namer()) :: :ok | {:error, term()}
  def store_all(plan, destination, kind) do
    Enum.reduce_while(plan, :ok, fn
      {path, {:store, name, value}}, :ok ->
        {:cont, stored(name, value, destination_of(destination, path), kind.(path))}

      {_path, {:keep, _name}}, :ok ->
        {:cont, :ok}
    end)
    |> halted()
  end

  defp destination_of(destination, path) when is_function(destination, 1), do: destination.(path)
  defp destination_of(destination, _path), do: destination

  defp halted(:ok), do: :ok
  defp halted(error), do: error

  defp stored(name, value, destination, kind) do
    with :ok <- bound(Secrets.get(name), name, destination, kind),
         do: Secrets.put_value(name, value)
  end

  defp bound(nil, name, destination, kind) do
    case Secrets.define(%{name: name, kind: kind, binding: [destination]}) do
      {:ok, _secret} -> :ok
      error -> error
    end
  end

  defp bound(%{binding: [destination]}, _name, destination, _kind), do: :ok
  defp bound(_secret, name, destination, _kind), do: Secrets.rebind(name, [destination])

  @doc """
  Persist a record's `changeset` (with its references in place) and store the
  planned values in OpenBao, in one transaction: a value OpenBao refuses
  undoes the row. The secrets the record no longer references are deleted
  once it has committed. `kind` gives each path's kind of secret; `persist`
  is `Repo.insert/1` or `Repo.update/1`.
  """
  @spec saved(Ecto.Changeset.t(), secrets(), namer(), (Ecto.Changeset.t() ->
                                                         {:ok, struct()} | {:error, term()})) ::
          {:ok, struct()} | {:error, term()}
  def saved(changeset, {plan, destination, dropped}, kind, persist) do
    Repo.transaction(fn ->
      with {:ok, record} <- persist.(changeset),
           :ok <- values_stored(store_all(plan, destination, kind), changeset) do
        record
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> dropped_after(dropped)
  end

  defp values_stored(:ok, _changeset), do: :ok

  defp values_stored({:error, reason}, changeset),
    do:
      {:error,
       Ecto.Changeset.add_error(changeset, :base, "credential not stored: #{describe(reason)}")}

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(_reason), do: "refused"

  defp dropped_after({:ok, _record} = result, dropped) do
    delete(dropped)
    result
  end

  defp dropped_after(error, _dropped), do: error

  @doc """
  The binding for a web origin: `origin:<scheme>://<host>[:<port>]` of an
  http(s) URL (the port only when it is not the scheme's default), or nil.
  """
  @spec origin_binding(term()) :: String.t() | nil
  def origin_binding(url) when is_binary(url), do: origin(URI.parse(url))
  def origin_binding(_url), do: nil

  defp origin(%URI{scheme: scheme, host: host, port: port})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: "origin:#{scheme}://#{host}#{port_part(scheme, port)}"

  defp origin(_uri), do: nil

  defp port_part("http", 80), do: ""
  defp port_part("https", 443), do: ""
  defp port_part(_scheme, nil), do: ""
  defp port_part(_scheme, port), do: ":#{port}"

  @doc "The binding for a destination URL: `host:<host>` of an http(s) URL, or nil."
  @spec url_binding(term()) :: String.t() | nil
  def url_binding(url) when is_binary(url), do: host_binding(URI.parse(url))
  def url_binding(_url), do: nil

  defp host_binding(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: "host:" <> host

  defp host_binding(_uri), do: nil

  @doc "Copy the secret `name` into a new secret `new`, same binding and kind."
  @spec copy(String.t(), String.t()) :: :ok | {:error, term()}
  def copy(name, new) do
    with %{binding: [destination] = binding, kind: kind} <- Secrets.get(name),
         {:ok, value} <- Secrets.resolve(name, for: destination),
         {:ok, _secret} <- Secrets.define(%{name: new, kind: kind, binding: binding}) do
      Secrets.put_value(new, value)
    else
      nil -> {:error, :unknown_secret}
      %AlexClaw.Secrets.Secret{} -> {:error, :not_owned}
      error -> error
    end
  end

  @doc "Delete the secrets `names`, each with every version. One already gone is no error."
  @spec delete([String.t()]) :: :ok
  def delete(names), do: Enum.each(names, &Secrets.delete/1)

  @doc "A secret name for a record's field: `<prefix>_<random>_<field>`, at most 64 characters."
  @spec name(String.t(), path()) :: String.t()
  def name(prefix, path) do
    field =
      path
      |> Enum.map_join("_", &to_string/1)
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")

    random = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    String.slice("#{prefix}_#{random}_#{field}", 0, 64)
  end
end
