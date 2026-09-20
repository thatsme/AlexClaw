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

  defp end_of_block(lines, start, indent) do
    lines
    |> Enum.drop(start)
    |> Enum.with_index(start + 1)
    |> Enum.find_value(length(lines), fn {line, n} ->
      if line == String.duplicate(" ", indent) <> "end", do: n
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

  # The two security-relevant tables are :protected, so a write from outside
  # the owner raises instead of quietly succeeding.
  test "the challenge and OAuth state tables are protected" do
    for path <- [
          "lib/alex_claw/auth/challenge_store.ex",
          "lib/alex_claw/google/token_manager.ex"
        ] do
      assert Regex.match?(
               ~r/:ets\.new\(@?\w+,\s*\[:named_table,\s*:protected/,
               File.read!(path)
             ),
             "#{path} owns security state, so its table must be :protected — a write " <>
               "from outside the owner should raise rather than succeed"
    end
  end
end
