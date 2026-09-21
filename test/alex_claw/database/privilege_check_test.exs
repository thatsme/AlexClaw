defmodule AlexClaw.Database.PrivilegeCheckTest do
  @moduledoc """
  The boot refuses a database connection with more power than the application
  needs, and says which powers. Enforced in production, unconditionally.
  """
  use ExUnit.Case, async: true
  @moduletag :integration

  alias AlexClaw.Database.PrivilegeCheck

  defp connect(username, password) do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: System.fetch_env!("DATABASE_HOSTNAME"),
        username: username,
        password: password,
        database: AlexClaw.Repo.config()[:database]
      )

    on_exit(fn -> Process.exit(conn, :normal) end)
    conn
  end

  test "the application role passes" do
    conn = connect(System.fetch_env!("DATABASE_USERNAME"), System.fetch_env!("DATABASE_PASSWORD"))
    assert PrivilegeCheck.check!(conn) == :ok
  end

  test "the owner is refused, with every reason and what to do about it" do
    conn =
      connect(
        System.fetch_env!("DATABASE_OWNER_USERNAME"),
        System.fetch_env!("DATABASE_OWNER_PASSWORD")
      )

    error = assert_raise RuntimeError, fn -> PrivilegeCheck.check!(conn) end

    assert error.message =~ "will not start on this database connection"
    assert error.message =~ "is a superuser"
    assert error.message =~ "owns tables"
    assert error.message =~ "DATABASE_OWNER_"
  end

  test "is off unless enforced, and enforced by the production config" do
    assert PrivilegeCheck.run!(false) == :ok

    runtime = File.read!("config/runtime.exs")
    [_before, prod] = String.split(runtime, "if config_env() == :prod do", parts: 2)
    assert prod =~ "config :alex_claw, enforce_db_privileges: true"
  end

  test "the boot runs it before any child starts" do
    source = File.read!("lib/alex_claw/application.ex")
    [before_children, _rest] = String.split(source, "children = [", parts: 2)
    assert before_children =~ "PrivilegeCheck.run!()"
  end
end
