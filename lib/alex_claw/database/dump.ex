defmodule AlexClaw.Database.Dump do
  @moduledoc """
  The full database as a `pg_dump` SQL script, streamed chunk by chunk.
  Performed as `:download_database` through `AlexClaw.ControlPlane.perform/3`.
  """

  @doc """
  Run `pg_dump` and hand each chunk of its output to `emit.(chunk, acc)`,
  which answers `{:ok, acc}` to go on or `{:error, reason}` to stop (the
  client went away). Returns the last `acc`.
  """
  @spec write(acc, (binary(), acc -> {:ok, acc} | {:error, term()})) :: acc when acc: term()
  def write(acc, emit) do
    config = connection()

    port =
      Port.open(
        {:spawn_executable, System.find_executable("pg_dump")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args(config),
          env: [{~c"PGPASSWORD", String.to_charlist(config.password)}]
        ]
      )

    stream(acc, port, emit)
  end

  defp stream(acc, port, emit) do
    receive do
      {^port, {:data, chunk}} -> chunk |> emit.(acc) |> emitted(acc, port, emit)
      {^port, {:exit_status, _status}} -> acc
    after
      60_000 ->
        Port.close(port)
        acc
    end
  end

  defp emitted({:ok, acc}, _previous, port, emit), do: stream(acc, port, emit)
  defp emitted({:error, _reason}, acc, _port, _emit), do: acc

  defp args(config) do
    [
      "-h",
      config.hostname,
      "-U",
      config.username,
      "-d",
      config.database,
      "--no-owner",
      "--no-privileges",
      "--clean",
      "--if-exists"
    ]
  end

  defp connection do
    %{
      hostname: System.get_env("DATABASE_HOSTNAME", "db"),
      username: System.get_env("DATABASE_USERNAME", "alexclaw"),
      password: System.get_env("DATABASE_PASSWORD", ""),
      database: "alex_claw_prod"
    }
  end
end
