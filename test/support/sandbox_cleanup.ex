defmodule AlexClaw.SandboxCleanup do
  @moduledoc """
  Run cleanup that writes to the database from an `on_exit` callback.

  `on_exit` runs in its own process after the test process has gone. A
  LiveView the test left behind is killed with it, and one killed mid-query
  takes the sandbox owner's shared connection down: cleanup that then writes —
  revoking an elevation writes its audit row — finds no connection and loses
  the row. So the callback checks out a connection of its own instead of
  depending on how the test ended.
  """

  alias Ecto.Adapters.SQL.Sandbox

  @doc "Run `fun` with a sandbox connection of this process's own."
  @spec run((-> result)) :: result when result: term()
  def run(fun) do
    Sandbox.checkout(AlexClaw.Repo)

    try do
      fun.()
    after
      Sandbox.checkin(AlexClaw.Repo)
    end
  end
end
