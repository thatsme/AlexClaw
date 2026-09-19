defmodule AlexClaw.Skills.CallPolicy do
  @moduledoc """
  Static containment check for generated skill source.

  A skill is *contained* when every remote call it makes resolves to a module on
  the allowlist. Containment is what lets generated code load without a TOTP
  challenge: the code cannot reach the filesystem, the network, the database or
  the VM except through `SkillAPI`, which enforces the skill's declared
  permissions.

  This is static analysis of direct calls only. It says nothing about what the
  allowed modules themselves do — `SkillAPI` really does act on the skill's
  behalf, and `Logger` really does write logs. It is a containment envelope, not
  a sandbox.
  """

  # Everything a generated skill needs to transform data and reach the outside
  # world through SkillAPI, and nothing that reaches it directly.
  @allowed_modules [
    AlexClaw.Skills.SkillAPI,
    AlexClaw.Skills.Helpers,
    Enum,
    Map,
    MapSet,
    List,
    Keyword,
    Tuple,
    Stream,
    Range,
    Access,
    String,
    Integer,
    Float,
    Regex,
    Jason,
    Base,
    URI,
    Path,
    Date,
    Time,
    DateTime,
    NaiveDateTime,
    Logger,
    SweetXml,
    Floki,
    :math
  ]

  # Allowed module, denied function: String.to_atom/1 creates atoms that are
  # never garbage collected, so untrusted input can exhaust the atom table.
  @denied_remote [{String, :to_atom}, {String, :to_charlist_atom}]

  # Locally-callable Kernel functions that escape the envelope.
  @denied_local [:spawn, :spawn_link, :spawn_monitor, :send, :apply]

  @type violation :: String.t()

  @doc """
  Check that every call in `ast` stays inside the allowlist.

  Returns `:ok`, or `{:error, violations}` with every violation found — the
  caller feeds the whole list back to the model, so stopping at the first one
  would cost a retry per violation.
  """
  @spec contained?(Macro.t()) :: :ok | {:error, [violation()]}
  def contained?(ast) do
    aliases = collect_aliases(ast)

    {_ast, violations} = Macro.prewalk(ast, [], &check_node(&1, &2, aliases))

    case violations |> Enum.reverse() |> Enum.uniq() do
      [] -> :ok
      found -> {:error, found}
    end
  end

  @doc "The modules a contained skill may call, for documentation and error messages."
  @spec allowed_modules() :: [module() | atom()]
  def allowed_modules, do: @allowed_modules

  # --- Alias resolution ---

  # Only the plain `alias A.B.C` form is understood. `as:` and the brace form are
  # reported as violations rather than resolved, so nothing slips through a shape
  # this checker does not model.
  defp collect_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _meta, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), Module.concat(parts))}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  # --- Node checks ---

  defp check_node({:alias, _meta, [_target, opts]} = node, acc, _aliases) when is_list(opts) do
    if Keyword.has_key?(opts, :as) do
      {node, ["alias ..., as: ... (cannot be resolved statically)" | acc]}
    else
      {node, acc}
    end
  end

  defp check_node({:alias, _meta, [{{:., _, [_base, :{}]}, _, _} | _]} = node, acc, _aliases) do
    {node, ["multi-alias A.{B, C} form (cannot be resolved statically)" | acc]}
  end

  defp check_node({{:., _meta, [target, fun]}, _call_meta, args} = node, acc, aliases)
       when is_atom(fun) and is_list(args) do
    {node, remote_violation(target, fun, length(args), aliases, acc)}
  end

  defp check_node({local, _meta, args} = node, acc, _aliases)
       when local in @denied_local and is_list(args) do
    {node, ["#{local}/#{length(args)} (not permitted in a contained skill)" | acc]}
  end

  defp check_node(node, acc, _aliases), do: {node, acc}

  # --- Remote call resolution ---

  defp remote_violation({:__MODULE__, _meta, _ctx}, _fun, _arity, _aliases, acc), do: acc

  defp remote_violation({:__aliases__, _meta, parts}, fun, arity, aliases, acc) do
    parts
    |> resolve_alias(aliases)
    |> judge_module(fun, arity, acc)
  end

  defp remote_violation(target, fun, arity, _aliases, acc) when is_atom(target) do
    judge_module(target, fun, arity, acc)
  end

  # A target that is not a literal module — a variable, or a module computed at
  # runtime — cannot be checked at all, so it is refused.
  defp remote_violation(_target, fun, arity, _aliases, acc) do
    ["dynamic dispatch to #{fun}/#{arity} (module not known statically)" | acc]
  end

  defp resolve_alias([head | rest], aliases) do
    case Map.fetch(aliases, head) do
      {:ok, resolved} when rest == [] -> resolved
      {:ok, resolved} -> Module.concat([resolved | rest])
      :error -> Module.concat([head | rest])
    end
  end

  defp judge_module(module, fun, arity, acc) do
    cond do
      {module, fun} in @denied_remote ->
        ["#{inspect(module)}.#{fun}/#{arity} (denied: creates atoms from runtime data)" | acc]

      apply_call?(module, fun) ->
        ["#{inspect(module)}.#{fun}/#{arity} (dynamic dispatch is not permitted)" | acc]

      module in @allowed_modules ->
        acc

      true ->
        ["#{inspect(module)}.#{fun}/#{arity} (not in allowlist)" | acc]
    end
  end

  defp apply_call?(module, :apply) when module in [Kernel, :erlang], do: true
  defp apply_call?(_module, _fun), do: false
end
