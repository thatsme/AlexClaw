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
  # function that an `init/1` calls, so a module can keep its own table name —
  # `Config.init/0`, `RateLimiter.init_table/0`. That second case is checked
  # rather than allow-listed: the enclosing function must actually be called
  # from inside some `def init(` body in lib/. A hand-maintained exception list
  # would rot, and what it would hide is the bug.

  @lib "lib/**/*.ex"

  defp sources, do: Path.wildcard(@lib)

  defp lines_of(body), do: String.split(body, "\n")

  # The line range of every `def init(...)` body in a file. Indentation-based
  # by design: a heuristic that over-approximated the safe region would hide
  # exactly what this test looks for.
  defp init_ranges(body) do
    lines = lines_of(body)

    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> Regex.match?(~r/^\s*def init\(/, line) end)
    |> Enum.map(fn {line, n} -> {n, end_of_block(lines, n, indent_of(line))} end)
  end

  defp indent_of(line), do: byte_size(line) - byte_size(String.trim_leading(line))

  defp end_of_block(lines, start, indent, closer \\ "end") do
    lines
    |> Enum.drop(start)
    |> Enum.with_index(start + 1)
    |> Enum.find_value(length(lines), fn {line, n} ->
      if line == String.duplicate(" ", indent) <> closer, do: n
    end)
  end

  # Every function name called from inside an `init/1` body anywhere in lib/.
  defp called_from_init do
    for path <- sources(),
        body = File.read!(path),
        {from, to} <- init_ranges(body),
        line <- Enum.slice(lines_of(body), from - 1, to - from + 1),
        [_, name] <- Regex.scan(~r/\b([a-z_][a-zA-Z0-9_]*)\(/, line),
        into: MapSet.new(),
        do: name
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

  test "every :ets.new is reachable only from a supervised init/1" do
    reachable = called_from_init()

    offenders =
      for path <- sources(),
          body = File.read!(path),
          lines = lines_of(body),
          ranges = init_ranges(body),
          {line, n} <- Enum.with_index(lines, 1),
          String.contains?(line, ":ets.new("),
          not Enum.any?(ranges, fn {from, to} -> n >= from and n <= to end),
          not MapSet.member?(reachable, enclosing_function(lines, n)),
          do: "#{path}:#{n} (in #{enclosing_function(lines, n)})"

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

  test "the auth table owners do no database or gateway work in the owner process" do
    offenders =
      for path <- @auth_owners,
          body = File.read!(path),
          lines = lines_of(body),
          allowed = off_owner_ranges(body),
          reachable = called_off_owner(body),
          {line, n} <- Enum.with_index(lines, 1),
          not comment?(line),
          Regex.match?(@io_call, line),
          not Enum.any?(allowed, fn {from, to} -> n >= from and n <= to end),
          not MapSet.member?(reachable, enclosing_function(lines, n)),
          do: "#{path}:#{n} #{String.trim(line)}"

    assert offenders == [],
           """
           I/O in a process that owns a :protected auth table:
             #{Enum.join(offenders, "\n  ")}

           These calls belong in a Task.Supervisor.start_child/2 block. The
           owner must not be the process that waits on a database or a gateway:
           a slow one blocks every grant, revoke and code attempt behind it, and
           a dead one exits rather than raising, taking the table with it.
           """
  end
end
