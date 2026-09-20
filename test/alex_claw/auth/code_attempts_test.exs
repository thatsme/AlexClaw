defmodule AlexClaw.Auth.CodeAttemptsTest do
  @moduledoc """
  The two limits, and why there are two.

  A per-session limit alone is not a limit: the session identifier is a cookie
  the attacker sends, so discarding it resets the count. The instance limit is
  the one that actually bounds guessing, and the session limit is what keeps an
  operator's fumbled code from being everyone's problem.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.CodeAttempts

  setup do
    CodeAttempts.reset()
    on_exit(&CodeAttempts.reset/0)
    {:ok, sid: "sid-#{System.unique_integer([:positive])}"}
  end

  describe "a session with no history" do
    test "may submit a code", %{sid: sid} do
      assert CodeAttempts.status(sid) == :ok
    end

    test "is not confused with a session that has one", %{sid: sid} do
      for _ <- 1..CodeAttempts.session_limit(), do: CodeAttempts.record_failure(sid)

      assert {:locked, :session, _until} = CodeAttempts.status(sid)
      assert CodeAttempts.status("another-sid") == :ok
    end
  end

  describe "the session limit" do
    test "tolerates wrong codes up to the limit", %{sid: sid} do
      for _ <- 1..(CodeAttempts.session_limit() - 1) do
        assert CodeAttempts.record_failure(sid) == :ok
      end

      assert CodeAttempts.status(sid) == :ok
    end

    test "locks the session on the third wrong code", %{sid: sid} do
      CodeAttempts.record_failure(sid)
      CodeAttempts.record_failure(sid)

      assert {:locked, :session, until} = CodeAttempts.record_failure(sid)
      assert {:locked, :session, ^until} = CodeAttempts.status(sid)
    end

    test "lasts five minutes and then lets go", %{sid: sid} do
      for _ <- 1..CodeAttempts.session_limit(), do: CodeAttempts.record_failure(sid)
      {:locked, :session, until} = CodeAttempts.status(sid)

      assert {:locked, :session, ^until} = CodeAttempts.status(sid, until - 1)
      assert CodeAttempts.status(sid, until) == :ok
      assert CodeAttempts.status(sid, until + 1) == :ok
    end

    test "a correct code clears the session's count", %{sid: sid} do
      CodeAttempts.record_failure(sid)
      CodeAttempts.record_failure(sid)

      :ok = CodeAttempts.record_success(sid)

      assert CodeAttempts.record_failure(sid) == :ok
      assert CodeAttempts.status(sid) == :ok
    end
  end

  describe "the instance limit" do
    # The attack the session limit misses: a new identifier per attempt.
    test "counts wrong codes from every session together" do
      for n <- 1..CodeAttempts.instance_limit() do
        CodeAttempts.record_failure("throwaway-#{n}")
      end

      assert {:locked, :instance, _until} = CodeAttempts.status("a-fresh-session")
    end

    test "locks everyone, including sessions that never guessed" do
      for n <- 1..CodeAttempts.instance_limit(), do: CodeAttempts.record_failure("sid-#{n}")

      assert {:locked, :instance, _until} = CodeAttempts.status("never-tried")
    end

    test "outranks the session lock in what it reports", %{sid: sid} do
      for n <- 1..CodeAttempts.instance_limit(), do: CodeAttempts.record_failure("sid-#{n}")

      # This session is locked on its own account too, but the instance lock is
      # the one that has to be reported: it lasts longer and means more.
      for _ <- 1..CodeAttempts.session_limit(), do: CodeAttempts.record_failure(sid)

      assert {:locked, :instance, _until} = CodeAttempts.status(sid)
    end

    test "lasts fifteen minutes" do
      for n <- 1..CodeAttempts.instance_limit(), do: CodeAttempts.record_failure("sid-#{n}")
      {:locked, :instance, until} = CodeAttempts.status("anyone")

      assert {:locked, :instance, ^until} = CodeAttempts.status("anyone", until - 1)
      assert CodeAttempts.status("anyone", until) == :ok
    end

    # Nine failures a day apart are not an attack. The window is what makes the
    # difference between a slow typist and a script.
    test "only counts failures inside its window" do
      for n <- 1..(CodeAttempts.instance_limit() - 1) do
        CodeAttempts.record_failure("sid-#{n}")
      end

      assert CodeAttempts.status("anyone") == :ok
      assert CodeAttempts.record_failure("one-more") != :ok
    end
  end

  describe "reset/0" do
    test "forgets everything", %{sid: sid} do
      for n <- 1..CodeAttempts.instance_limit(), do: CodeAttempts.record_failure("sid-#{n}")

      :ok = CodeAttempts.reset()

      assert CodeAttempts.status(sid) == :ok
      assert CodeAttempts.status("anyone") == :ok
    end
  end

  describe "an unidentified session" do
    # A session without a sid cannot be locked individually, and must still be
    # counted against the instance rather than being a free guess.
    test "still counts against the instance" do
      for _ <- 1..CodeAttempts.instance_limit(), do: CodeAttempts.record_failure(nil)

      assert {:locked, :instance, _until} = CodeAttempts.status("anyone")
    end
  end
end
