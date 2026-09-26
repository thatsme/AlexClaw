defmodule AlexClaw.WebAutomation.Recording do
  @moduledoc """
  Logins in recordings and recipes: references to OpenBao secrets, bound to
  the site the recipe runs on.

  The sidecar records a credential field (a password, a one-time code) as a
  slot: a fill with no value. `to_recipe/2` turns the captured actions into a
  recipe in which such a fill's value is `%{"secret" => nil}`, a login still
  to be attached; any other fill keeps its value. `attach_login/3` stores a
  login in OpenBao, bound to the recipe's origin
  (`origin:<scheme>://<host>[:<port>]` of its `url`), and puts the reference
  in the slot. `resolved/1` hands back the recipe with every reference
  replaced by its value, resolved for that origin: what a play sends to the
  sidecar, each login fill marked with its `origin`, so the sidecar types it
  only on a page of that origin. A recipe moved to another site does not get
  the login.

  A fill value that is a reference is stored like any other value in a
  recipe; the contract (`AlexClaw.WebAutomation.Recipe`) is checked on a copy
  with each login blank, since a login's value is text only once resolved.
  """
  alias AlexClaw.Auth.SafeExecutor
  alias AlexClaw.Secrets
  alias AlexClaw.Secrets.Owned
  alias AlexClaw.WebAutomation.Recipe

  @slot %{"secret" => nil}
  @recipe_keys ~w(steps extra_steps)

  @doc """
  The recipe for a recording made on `url` from the sidecar's captured
  `actions`: only what a recipe can replay, a credential fill as an empty
  slot. `{:error, reasons}` when it breaks the contract.
  """
  @spec to_recipe(String.t() | nil, [map()]) :: {:ok, map()} | {:error, [String.t()]}
  def to_recipe(url, actions) do
    %{"url" => url, "steps" => Enum.flat_map(actions, &step/1)}
    |> validate()
  end

  defp step(%{"action_type" => "check"} = action),
    do: [%{"action" => "check", "selector" => action["selector"], "checked" => action["checked"]}]

  defp step(%{"action_type" => "click"} = action),
    do: [%{"action" => "click", "selector" => action["selector"]}]

  defp step(%{"action_type" => "fill", "secret" => true} = action),
    do: [%{"action" => "fill", "selector" => action["selector"], "value" => @slot}]

  defp step(%{"action_type" => type} = action) when type in ["fill", "select"],
    do: [%{"action" => type, "selector" => action["selector"], "value" => action["value"] || ""}]

  defp step(_action), do: []

  @doc "`recipe` checked against the contract, with each login blank; the recipe itself on success."
  @spec validate(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(recipe), do: recipe |> blank_logins() |> Recipe.validate() |> validated(recipe)

  # A login is text only once resolved: references and slots are checked as "".
  defp blank_logins(recipe) do
    paths = Map.keys(references(recipe)) ++ Enum.map(slots(recipe), &elem(&1, 0))
    Enum.reduce(paths, recipe, &Owned.put(&2, &1, ""))
  end

  defp validated({:ok, _blank}, recipe), do: {:ok, recipe}
  defp validated(error, _recipe), do: error

  @doc "The selectors of the fills still waiting for a login."
  @spec login_slots(map()) :: [String.t()]
  def login_slots(recipe), do: Enum.map(slots(recipe), &elem(&1, 1))

  defp slots(recipe) do
    for key <- @recipe_keys,
        {%{"action" => "fill", "value" => @slot} = step, index} <- indexed(recipe[key]),
        do: {[key, index, "value"], step["selector"]}
  end

  @doc """
  The recipe's fill values as fields (path => value): each literal value, and
  each reference to a login. An empty slot is not one.
  """
  @spec fields(map() | nil) :: %{Owned.path() => term()}
  def fields(recipe) when is_map(recipe) do
    for key <- @recipe_keys,
        {%{"action" => "fill", "value" => value}, index} <- indexed(recipe[key]),
        value not in [nil, "", @slot],
        into: %{},
        do: {[key, index, "value"], value}
  end

  def fields(_recipe), do: %{}

  @doc "The logins `recipe` references, as path => secret name."
  @spec references(map() | nil) :: %{Owned.path() => String.t()}
  def references(recipe), do: recipe |> fields() |> Owned.references()

  @doc "The destination a recipe's logins are bound to: the origin of its `url`, else of `fallback_url`."
  @spec destination(map() | nil, String.t() | nil) :: String.t() | nil
  def destination(%{"url" => url}, _fallback_url) when is_binary(url) and url != "",
    do: Owned.origin_binding(url)

  def destination(_recipe, fallback_url), do: Owned.origin_binding(fallback_url)

  defp indexed(steps) when is_list(steps), do: Enum.with_index(steps)
  defp indexed(_steps), do: []

  @doc """
  Store `value` as the login for the slot at `selector`, bound to the recipe's
  origin, and put the reference in the slot.
  """
  @spec attach_login(map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :no_login_slot | :no_origin | term()}
  def attach_login(recipe, selector, value) when is_binary(value) and value != "" do
    with {:ok, path} <- slot_path(recipe, selector),
         {:ok, destination} <- origin(recipe),
         name = Owned.name("recording", ["login"]),
         :ok <-
           Owned.store_all(%{path => {:store, name, value}}, destination, fn _ -> "login" end) do
      {:ok, Owned.put(recipe, path, Owned.reference(name))}
    end
  end

  @doc """
  `recipe` with `value` in the slot at `selector`, not yet stored: for a
  record saved through its one write point (`AlexClaw.Resources`), which
  stores the value in OpenBao, bound to the recipe's origin, and keeps the
  reference.
  """
  @spec filled(map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :no_login_slot | :empty_login}
  def filled(_recipe, _selector, value) when value in [nil, ""], do: {:error, :empty_login}

  def filled(recipe, selector, value) when is_binary(value) do
    with {:ok, path} <- slot_path(recipe, selector), do: {:ok, Owned.put(recipe, path, value)}
  end

  defp slot_path(recipe, selector) do
    case Enum.find(slots(recipe), &(elem(&1, 1) == selector)) do
      {path, _selector} -> {:ok, path}
      nil -> {:error, :no_login_slot}
    end
  end

  defp origin(recipe) do
    case destination(recipe, nil) do
      nil -> {:error, :no_origin}
      origin -> {:ok, origin}
    end
  end

  @doc """
  `recipe` with every login replaced by its value, resolved for the recipe's
  origin, and marked with that origin: what a play sends to the sidecar, which
  types a login only on a page of that origin (S8 H2/H3). A slot still empty
  is `{:error, {:login_required, selectors}}`; a login bound to another origin,
  or one the running step was not given
  (`AlexClaw.Auth.SafeExecutor.secret_allowed?/1`), is
  `{:error, {:not_bound, selector}}`. Every use is audited.
  """
  @spec resolved(map()) ::
          {:ok, map()}
          | {:error,
             {:login_required, [String.t()]}
             | {:not_bound, String.t()}
             | {:login_unavailable, String.t(), term()}}
  def resolved(recipe), do: resolved(login_slots(recipe), recipe)

  defp resolved([_ | _] = selectors, _recipe), do: {:error, {:login_required, selectors}}

  defp resolved([], recipe) do
    destination = destination(recipe, nil)

    recipe
    |> fields()
    |> logins()
    |> Enum.reduce_while({:ok, recipe}, fn {path, name}, {:ok, acc} ->
      case resolve(name, destination) do
        {:ok, value} ->
          {:cont, {:ok, acc |> Owned.put(path, value) |> with_origin(path, destination)}}

        {:error, reason} ->
          {:halt, refused(reason, selector_at(recipe, path))}
      end
    end)
  end

  # A play's logins: references when it is played from the admin UI, the
  # placeholders the step was given when it runs in a workflow.
  defp logins(fields), do: Map.merge(Owned.references(fields), Owned.given(fields))

  defp resolve(_name, nil), do: {:error, :not_bound}

  defp resolve(name, destination),
    do: given(SafeExecutor.secret_allowed?(name), name, destination)

  defp given(false, _name, _destination), do: {:error, :not_bound}
  defp given(true, name, destination), do: Secrets.resolve(name, for: destination)

  defp with_origin(recipe, path, "origin:" <> origin),
    do: Owned.put(recipe, List.replace_at(path, -1, "origin"), origin)

  defp refused(:not_bound, selector), do: {:error, {:not_bound, selector}}
  defp refused(reason, selector), do: {:error, {:login_unavailable, selector, reason}}

  defp selector_at(recipe, path),
    do: Owned.get(recipe, List.replace_at(path, -1, "selector"))
end
