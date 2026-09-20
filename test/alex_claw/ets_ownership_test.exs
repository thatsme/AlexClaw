defmodule AlexClaw.ETSOwnershipTest do
  use ExUnit.Case, async: true
  @moduletag :docs

  # An ETS table belongs to the process that created it and dies with it. A
  # table created lazily — on first use, by whichever caller got there first —
  # therefore has an owner nobody chose. Three tables were built that way, and
  # one held pending 2FA challenges: a LiveView created it, and closing that tab
  # discarded every challenge in flight.
  #
  # This fails the build when a new one appears.
  #
  # `:ets.new` is allowed inside an `init/1` callback, where a supervised
  # process takes ownership for its whole lifetime. It is also allowed in a
  # function that an `init/1` reaches, so a module can keep its own table name —
  # `Config.init/0`, `RateLimiter.init_table/0`. That second case is checked
  # rather than allow-listed: the enclosing function must actually be reachable
  # from some supervised `init/1`, across modules and to a fixpoint. A
  # hand-maintained exception list would rot, and what it would hide is the bug.

  @lib "lib/**/*.ex"

  defp sources, do: Path.wildcard(@lib)

  defp lines_of(body), do: String.split(body, "\n")

  defp indent_of(line), do: byte_size(line) - byte_size(String.trim_leading(line))

  defp end_of_block(lines, start, indent, closer \\ "end") do
    lines
    |> Enum.drop(start)
    |> Enum.with_index(start + 1)
    |> Enum.find_value(length(lines), fn {line, n} ->
      if line == String.duplicate(" ", indent) <> closer, do: n
    end)
  end

  # Everything any supervised init/1 reaches, across modules, to a fixpoint.
  defp reachable_from_init do
    files = files()
    expand(init_seeds(files), index(files), files)
  end

  # The name of the function enclosing a line, found by looking upwards.
  defp enclosing_function(lines, n) do
    lines
    |> Enum.take(n)
    |> Enum.reverse()
    |> Enum.find_value("?", fn line ->
      case Regex.run(~r/^\s*defp?\s+([a-z_][a-zA-Z0-9_]*)[\(\s]/, line) do
        [_, name] -> name
        nil -> nil
      end
    end)
  end

  # Reachability is module-aware and follows calls to a fixpoint, which is what
  # `reachable_from_init/0` below does. It used to collect the names called
  # inside `def init(` bodies, one level and project-wide, and that stopped
  # working the moment Config.Loader.init/1 delegated its body to boot/1: the
  # tables boot/1 creates are owned by the same supervised process as before,
  # and a one-level scan could no longer see it.
  test "every :ets.new is reachable only from a supervised init/1" do
    reachable = reachable_from_init()

    offenders =
      for {path, file} <- files(),
          {line, n} <- Enum.with_index(file.lines, 1),
          String.contains?(line, ":ets.new("),
          not comment?(line),
          not MapSet.member?(reachable, {file.module, enclosing_function(file.lines, n)}),
          do: "#{path}:#{n} (in #{enclosing_function(file.lines, n)})"

    assert offenders == [],
           """
           :ets.new outside a supervised init/1, and not called from one:
             #{Enum.join(offenders, "\n  ")}

           A table created this way is owned by whichever process happened to
           call first, and dies with it. Create it in the init/1 of a process
           that lives as long as the data should, or in a function that such an
           init/1 calls.
           """
  end

  # A `whereis` guard is not wrong in itself: Config.init/0 is re-entrant by
  # design, called again on every cluster config change, and the guard is what
  # makes that idempotent. It was wrong in these three, where it meant "create
  # on first use, owned by whoever got here first".
  @formerly_lazy ~w(
    lib/alex_claw/auth/challenge_store.ex
    lib/alex_claw/google/token_manager.ex
    lib/alex_claw/rag/query_rewriter.ex
  )

  test "the tables that were lazily created are not lazily created again" do
    for path <- @formerly_lazy do
      refute String.contains?(File.read!(path), ":ets.whereis("),
             "#{path} guards :ets.new with :ets.whereis again — that is lazy creation " <>
               "returning, and with it the race where two first-callers both see " <>
               ":undefined and the loser raises"
    end
  end

  test "TOTP and OAuth no longer own tables at all" do
    for path <- ~w(lib/alex_claw/auth/totp.ex lib/alex_claw/google/oauth.ex) do
      refute String.contains?(File.read!(path), ":ets.new("),
             "#{path} creates a table again — its state belongs to a supervised owner"
    end
  end

  # The table is named, not just the file. A file-wide search is satisfied by
  # any one :ets.new in it, which is how :google_token_cache sat :public behind
  # an assertion that was satisfied by the OAuth state table beside it.
  #
  # :protected — a write from outside the owner raises rather than quietly
  # succeeding. For elevations that is the whole guarantee: a process that
  # could insert a row could elevate itself.
  #
  # :private — nothing outside the owner can even read. The Google token cache
  # holds bearer credentials, and a dynamic skill runs in this VM.
  @table_visibility [
    {"lib/alex_claw/auth/challenge_store.ex", "@table", ":protected"},
    {"lib/alex_claw/auth/code_attempts.ex", "@table", ":protected"},
    {"lib/alex_claw/auth/elevation.ex", "@table", ":protected"},
    {"lib/alex_claw/google/token_manager.ex", "@state_table", ":protected"},
    {"lib/alex_claw/google/token_manager.ex", "@table", ":private"}
  ]

  test "the security tables are created at the visibility they were given" do
    for {path, attr, visibility} <- @table_visibility do
      pattern = ~r/:ets\.new\(#{Regex.escape(attr)},\s*\[:named_table,\s*#{visibility}/

      assert Regex.match?(pattern, File.read!(path)),
             "#{path} must create #{attr} as #{visibility}. " <>
               ":protected means a write from outside the owner raises rather " <>
               "than quietly succeeding; :private means nothing outside the " <>
               "owner can read it either."
    end
  end

  # A :protected table is a boundary only while the process holding it is alive
  # and answering. I/O inside that process threatens both. A database that has
  # gone away exits rather than raising, and an exit takes the table with it —
  # which for elevations means every live one silently revoked because an audit
  # row could not be written. A gateway that hangs does the slower version of
  # the same damage, with the owner blocked at the moment it matters most.
  #
  # So the auth table owners hand their database and gateway work to a task
  # under AlexClaw.TaskSupervisor, and this fails the build when one of them
  # does it inline again. Found in 0.3.27 the hard way, as one intermittent
  # failure in a full suite run that passed alone under every seed.
  #
  # TokenManager is deliberately not here: talking to Google is its whole job,
  # and what it owns is a cache rather than a boundary.
  @auth_owners ~w(
    lib/alex_claw/auth/challenge_store.ex
    lib/alex_claw/auth/code_attempts.ex
    lib/alex_claw/auth/elevation.ex
  )

  @io_call ~r/\b(AuditLog|Repo|Router)\./

  defp comment?(line), do: String.starts_with?(String.trim_leading(line), "#")

  # The line range of every `Task.Supervisor.start_child(` block, which is the
  # one place in these modules where an I/O call is allowed to appear.
  defp off_owner_ranges(body) do
    lines = lines_of(body)

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} ->
      Regex.match?(~r/Task\.Supervisor\.start_child\(/, line)
    end)
    |> Enum.map(fn {line, n} -> {n, end_of_block(lines, n, indent_of(line), "end)")} end)
  end

  # Every function name called from inside an off-owner block in this file.
  # Same reasoning as `called_from_init/0`: a module is allowed to keep its own
  # helper — `notify/1` in CodeAttempts — as long as the task is what reaches
  # it. One level deep, checked rather than allow-listed, because a list of
  # exceptions would rot and what it would hide is the bug.
  defp called_off_owner(body) do
    lines = lines_of(body)

    for {from, to} <- off_owner_ranges(body),
        line <- Enum.slice(lines, from - 1, to - from + 1),
        [_, name] <- Regex.scan(~r/\b([a-z_][a-zA-Z0-9_]*)\(/, line),
        into: MapSet.new(),
        do: name
  end

  @callbacks ~w(init handle_call handle_cast handle_info handle_continue terminate)

  # Every `def`/`defp` in a file, by name, with the lines it spans. A one-line
  # `do:` clause spans itself; anything else runs to the `end` at its own
  # indentation.
  defp def_spans(body) do
    lines = lines_of(body)

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> Regex.match?(~r/^\s*defp?\s+[a-z_]/, line) end)
    |> Enum.map(fn {line, n} -> {def_name(line), span(lines, line, n)} end)
  end

  defp def_name(line) do
    [_, name] = Regex.run(~r/^\s*defp?\s+([a-z_][a-zA-Z0-9_]*)/, line)
    name
  end

  defp span(lines, line, n), do: span(lines, line, n, String.contains?(line, ", do:"))
  defp span(_lines, _line, n, true), do: {n, n}
  defp span(lines, line, n, false), do: {n, end_of_block(lines, n, indent_of(line))}

  defp owner_functions(body), do: reachable_from(body, @callbacks)

  # The functions in a file reachable from a given set of entry points, to a
  # fixpoint. Seeded with the GenServer callbacks it gives the code that runs
  # *in* the owner process, which is the distinction that matters: a client
  # function in the same module runs in the caller, where waiting on the
  # database is not only allowed but wanted — Elevation.grant/1 writes its audit
  # row there on purpose, so the record exists before anyone is told the
  # elevation holds. Seeded with init it gives the code that runs during boot.
  #
  # A fixpoint rather than one level: the write that started all this sat two
  # calls deep, in drop/3 behind end_elevation/2, and both database reads that
  # held up the boot were one call below init.
  defp reachable_from(body, entry_points) do
    spans = def_spans(body)
    seeds = for {name, _span} <- spans, name in entry_points, into: MapSet.new(), do: name

    grow(seeds, spans, lines_of(body))
  end

  defp grow(names, spans, lines) do
    grown =
      for {name, {from, to}} <- spans,
          MapSet.member?(names, name),
          line <- Enum.slice(lines, from - 1, to - from + 1),
          [_, called] <- Regex.scan(~r/\b([a-z_][a-zA-Z0-9_]*)\(/, line),
          into: names,
          do: called

    settled(MapSet.equal?(grown, names), grown, spans, lines)
  end

  defp settled(true, names, _spans, _lines), do: names
  defp settled(false, names, spans, lines), do: grow(names, spans, lines)

  test "the auth table owners do no database or gateway work in the owner process" do
    offenders =
      for path <- @auth_owners,
          body = File.read!(path),
          lines = lines_of(body),
          allowed = off_owner_ranges(body),
          off_owner = called_off_owner(body),
          owner = owner_functions(body),
          {line, n} <- Enum.with_index(lines, 1),
          not comment?(line),
          Regex.match?(@io_call, line),
          MapSet.member?(owner, enclosing_function(lines, n)),
          not Enum.any?(allowed, fn {from, to} -> n >= from and n <= to end),
          not MapSet.member?(off_owner, enclosing_function(lines, n)),
          do: "#{path}:#{n} #{String.trim(line)}"

    assert offenders == [],
           """
           I/O in a process that owns a :protected auth table:
             #{Enum.join(offenders, "\n  ")}

           The owner must not be the process that waits on a database or a
           gateway: a slow one blocks every grant, revoke and code attempt
           behind it, and a dead one exits rather than raising, taking the
           table with it.

           Two places this work can go. A client function in the same module
           runs in the caller, which is where an audit row belongs when someone
           is about to be told the action succeeded. Anything with no caller to
           run in belongs in a Task.Supervisor.start_child/2 block.
           """
  end

  # The other half of the rule above. Keeping work out of the owner says where
  # it must not run. For a row recording something a person has just done, it
  # also matters that it does not merely run somewhere else eventually: a grant
  # and a revoke are written by the caller, inline, so the record exists before
  # the caller reports success. An expiry has nobody to report to and no caller
  # to run in, so it is deferred.
  #
  # Structural because the timing is not observable. A deferred write lands
  # before a test can look — and Ecto's sandbox follows $callers into a
  # supervised task, so even a non-shared connection does not stop it — which
  # means a test that reads the row back passes whichever process wrote it.
  # That was tried first and it passed against a deliberately broken version.
  @elevation_rows [
    {"audit_expired", :deferred},
    {"audit_revoked", :inline},
    {"grant", :inline}
  ]

  test "a grant and a revoke are audited by the caller, an expiry is deferred" do
    body = File.read!("lib/alex_claw/auth/elevation.ex")
    lines = lines_of(body)
    deferred = off_owner_ranges(body)

    found =
      for {line, n} <- Enum.with_index(lines, 1),
          not comment?(line),
          String.contains?(line, "AuditLog.log_elevation("),
          do: {enclosing_function(lines, n), placement(deferred, n)}

    assert Enum.sort(found) == @elevation_rows,
           """
           The elevation audit rows are not written where they should be.
             found:    #{inspect(Enum.sort(found))}
             expected: #{inspect(@elevation_rows)}

           :inline means the caller writes it and waits — which is the point,
           because the caller is about to tell someone the action succeeded.
           :deferred means a Task.Supervisor.start_child/2 block, which is for
           work with no caller to run in.
           """
  end

  defp placement(deferred, n) do
    placement(Enum.any?(deferred, fn {from, to} -> n >= from and n <= to end))
  end

  defp placement(true), do: :deferred
  defp placement(false), do: :inline

  # A database read in init/1 makes the boot depend on the database being up.
  # The supervisor starts children in order and init/1 runs before start_link
  # returns, so every child after this one waits on that query — SkillRegistry
  # was child 7 of 25 — and a database that is a few seconds behind the app
  # turns a delay into a crash loop rather than a slow start.
  #
  # handle_continue/2 is where this belongs: it runs before any other message,
  # so a caller going through the process still sees a finished load, and the
  # supervisor is no longer holding the rest of the tree behind it.
  #
  # Reachability, and across modules. Neither of the two reads this was written
  # for was in an init body — both were a call below, in load_today_from_db/0
  # and load_dynamic_skills_from_db/0 — and the first version of this check
  # walked calls per file, which is why it passed while Config.Loader.init/1
  # sat there reaching AlexClaw.Config.load_all_into_ets/0 in another module
  # and failing the boot before either of them ran.
  #
  # Entry points are `def init(` of arity one only: AlexClaw.Config.init/0 and
  # MCP.Server.init/2 are ordinary functions that happen to share the name.
  @blocking_by_design %{
    "AlexClaw.Config.Loader" => """
    Intentional, and the only one that should be. Configuration is a hard
    dependency of everything else, so this waits for the database — 1s, 2s, 5s,
    then every 5s, up to a minute — and stops the boot rather than starting an
    agent on defaults nobody chose.
    """,
    "AlexClaw.Cluster.Manager" => """
    Found by this check, not yet decided. auto_register_self/0 writes this
    node's row from init/1, so the same crash loop applies, and the plan for
    batch 2d never listed it.
    """,
    "AlexClaw.Reasoning.Loop" => """
    Found by this check, not yet decided. Not a boot dependency: a
    DynamicSupervisor starts one per reasoning run (loop.ex:63), so its init/1
    blocks whoever asked for the run rather than the supervision tree. Refusing
    to start a run when the database is down may well be correct.
    """
  }

  test "no supervised init/1 waits on the database" do
    offenders =
      for {module, where} <- repo_calls_reachable_from_init(),
          not Map.has_key?(@blocking_by_design, module),
          do: "#{where}  (reached from #{module}.init/1)"

    assert offenders == [],
           """
           A database call reachable from init/1:
             #{offenders |> Enum.sort() |> Enum.join("\n  ")}

           Move it to handle_continue/2 and return {:ok, state, {:continue, _}}
           from init/1. The process stays correct — a continue runs before any
           other message — and stops holding up every child started after it.

           If the boot genuinely cannot proceed without it, add the module to
           @blocking_by_design with the reason.
           """
  end

  # Every allow-list entry has to still be true, or the list is a place where
  # findings go to be forgotten.
  test "every module allowed to block the boot still does" do
    blocking = repo_calls_reachable_from_init() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    stale =
      for module <- Map.keys(@blocking_by_design),
          not MapSet.member?(blocking, module),
          do: module

    assert stale == [],
           "no longer reaches the database from init/1, so the entry can go: " <>
             Enum.join(stale, ", ")
  end

  # --- cross-module reachability ---

  defp files do
    for path <- sources(), into: %{} do
      body = File.read!(path)

      {path,
       %{body: body, lines: lines_of(body), module: module_of(body), aliases: aliases_of(body)}}
    end
  end

  defp module_of(body) do
    case Regex.run(~r/^defmodule\s+([A-Za-z0-9_.]+)\s+do/m, body) do
      [_, name] -> name
      nil -> nil
    end
  end

  # `alias A.B.C`, `alias A.B.{C, D}` and `alias A.B.C, as: D`, short name to full.
  defp aliases_of(body) do
    plain =
      for [_, full] <- Regex.scan(~r/^\s*alias\s+([A-Za-z0-9_.]+)\s*$/m, body),
          into: %{},
          do: {full |> String.split(".") |> List.last(), full}

    grouped =
      for [_, prefix, inner] <- Regex.scan(~r/^\s*alias\s+([A-Za-z0-9_.]+)\.\{([^}]+)\}/m, body),
          part <- String.split(inner, ","),
          short = String.trim(part),
          short != "",
          into: %{},
          do: {short, prefix <> "." <> short}

    renamed =
      for [_, full, short] <-
            Regex.scan(~r/^\s*alias\s+([A-Za-z0-9_.]+),\s*as:\s*([A-Za-z0-9_]+)/m, body),
          into: %{},
          do: {short, full}

    plain |> Map.merge(grouped) |> Map.merge(renamed)
  end

  defp index(files) do
    for {path, file} <- files,
        file.module != nil,
        {name, span} <- def_spans(file.body),
        reduce: %{} do
      acc -> Map.update(acc, {file.module, name}, [{path, span}], &[{path, span} | &1])
    end
  end

  defp init_seeds(files) do
    for {_path, file} <- files,
        file.module != nil,
        {line, _n} <- Enum.with_index(file.lines, 1),
        Regex.match?(~r/^\s*def init\(/, line),
        arity_of(line) == 1,
        into: MapSet.new(),
        do: {file.module, "init"}
  end

  # Top-level commas in the head's argument list, which is enough to tell
  # init/0, init/1 and init/2 apart.
  defp arity_of(line) do
    case Regex.run(~r/^\s*defp?\s+[a-z_][a-zA-Z0-9_]*\((.*)$/, line) do
      nil -> 0
      [_, rest] -> rest |> args_of() |> count_args()
    end
  end

  defp args_of(rest), do: args_of(String.graphemes(rest), 0, [])

  defp args_of([], _depth, taken), do: taken |> Enum.reverse() |> Enum.join()
  defp args_of([")" | _rest], 0, taken), do: taken |> Enum.reverse() |> Enum.join()

  defp args_of([c | rest], depth, taken) when c in ["(", "{", "["] do
    args_of(rest, depth + 1, [c | taken])
  end

  defp args_of([c | rest], depth, taken) when c in [")", "}", "]"] do
    args_of(rest, depth - 1, [c | taken])
  end

  defp args_of([c | rest], depth, taken), do: args_of(rest, depth, [c | taken])

  defp count_args(""), do: 0

  defp count_args(args) do
    args
    |> String.graphemes()
    |> Enum.reduce({1, 0}, fn
      c, {n, depth} when c in ["(", "{", "["] -> {n, depth + 1}
      c, {n, depth} when c in [")", "}", "]"] -> {n, depth - 1}
      ",", {n, 0} -> {n + 1, 0}
      _c, acc -> acc
    end)
    |> elem(0)
  end

  defp calls_from({module, _name}, path, {from, to}, files) do
    file = files[path]
    body_lines = Enum.slice(file.lines, from - 1, to - from + 1)

    qualified =
      for line <- body_lines,
          not comment?(line),
          [_, prefix, called] <-
            Regex.scan(~r/([A-Z][A-Za-z0-9_.]*)\.([a-z_][a-zA-Z0-9_]*)\(/, line),
          do: {Map.get(file.aliases, prefix, prefix), called}

    local =
      for line <- body_lines,
          not comment?(line),
          [_, called] <- Regex.scan(~r/(?<![.\w:])([a-z_][a-zA-Z0-9_]*)\(/, line),
          do: {module, called}

    qualified ++ local
  end

  # Named apart from grow/3 above, which is the per-file walk. Two functions of
  # the same name and arity in one module are clauses of one function, and the
  # first one written wins — which is how this returned the seed and nothing
  # else, and how the check passed by finding nothing.
  defp expand(frontier, index, files) do
    next =
      for key <- frontier,
          {path, span} <- Map.get(index, key, []),
          call <- calls_from(key, path, span, files),
          Map.has_key?(index, call),
          into: frontier,
          do: call

    if MapSet.equal?(next, frontier), do: frontier, else: expand(next, index, files)
  end

  # {module whose init/1 reaches it, "path:line  source"} for every Repo call.
  defp repo_calls_reachable_from_init do
    files = files()
    index = index(files)

    for {module, "init"} = seed <- init_seeds(files),
        key <- expand(MapSet.new([seed]), index, files),
        {path, {from, to}} <- Map.get(index, key, []),
        {line, n} <- Enum.with_index(files[path].lines, 1),
        n >= from and n <= to,
        not comment?(line),
        Regex.match?(~r/\bRepo\./, line),
        uniq: true,
        do: {module, "#{path}:#{n}  #{String.trim(line)}"}
  end
end
