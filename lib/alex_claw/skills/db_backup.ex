defmodule AlexClaw.Skills.DbBackup do
  @moduledoc """
  Core skill that creates a PostgreSQL backup via pg_dump and saves it
  to a host-mounted directory. Rotates backups — keeps N most recent.
  Designed to run as a scheduled workflow step.

  Config keys (Admin UI > Config, category: backup):
  - `backup.enabled` — enable/disable backups
  - `backup.max_files` — max backup files to keep (default 7)
  """
  @behaviour AlexClaw.Skill

  require Logger

  alias AlexClaw.Config

  # Bind-mounted from the host in docker-compose.yml (${BACKUP_DIR:-./backups}).
  # This was referenced four times but never defined, so it evaluated to nil and
  # every call would have failed had the enabled check above ever passed.
  @backup_dir "/app/backups"

  @impl true
  @spec description() :: String.t()
  def description, do: "Database backup with rotation (host-mounted)"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_success, :on_error]

  @impl true
  @spec step_fields() :: [atom()]
  def step_fields, do: []

  @impl true
  @spec run(map()) :: {:ok, String.t(), atom()} | {:error, any()}
  def run(_args) do
    if Config.enabled?("backup.enabled") do
      max_files = Config.get("backup.max_files") || 7

      with :ok <- verify_mount(@backup_dir),
           :ok <- ensure_dir(@backup_dir),
           {:ok, filename} <- dump(@backup_dir),
           {:ok, rotation} <- rotate(@backup_dir, max_files) do
        summary = summary(filename, rotation)
        Logger.info(summary, skill: :db_backup)
        {:ok, summary, :on_success}
      else
        {:error, reason} ->
          Logger.error("Database backup failed: #{inspect(reason)}", skill: :db_backup)
          {:error, reason}
      end
    else
      {:error, :backup_disabled}
    end
  end

  # What was deleted is counted; what could not be deleted is named.
  defp summary(filename, %{deleted: deleted, failed: []}),
    do: "Backup saved: #{filename} (rotated #{length(deleted)} old backups)"

  defp summary(filename, %{deleted: deleted, failed: failed}) do
    names =
      Enum.map_join(failed, ", ", fn {path, reason} ->
        "#{Path.basename(path)} (#{inspect(reason)})"
      end)

    "Backup saved: #{filename} (rotated #{length(deleted)} old backups; could not delete #{names})"
  end

  defp verify_mount(dir) do
    # Check if the backup dir is a bind mount (not on the container overlay FS).
    # Strategy: check /proc/mounts first (works on all Docker runtimes including
    # Docker Desktop on Windows/Mac), fall back to device ID comparison.
    cond do
      mount_entry?(dir) ->
        :ok

      different_device?(dir) ->
        :ok

      File.exists?(dir) ->
        Logger.warning(
          "Backup dir #{dir} is NOT a separate mount — backups will be lost on container recreation",
          skill: :db_backup
        )

        {:error,
         {:not_mounted,
          "#{dir} is on the same filesystem as /app — configure a bind mount in docker-compose.yml"}}

      true ->
        # Dir doesn't exist yet — ensure_dir will create it.
        # Can't verify mount before the dir exists, but if the bind mount is
        # configured in docker-compose.yml, Docker creates the mount point.
        # If it doesn't exist, the mount is likely missing.
        Logger.warning(
          "Backup dir #{dir} does not exist — is the bind mount configured in docker-compose.yml?",
          skill: :db_backup
        )

        {:error, {:not_mounted, "#{dir} does not exist — add a bind mount in docker-compose.yml"}}
    end
  end

  defp mount_entry?(dir) do
    case File.read("/proc/mounts") do
      {:ok, content} -> mounted_at?(content, dir)
      {:error, _} -> false
    end
  end

  defp mounted_at?(content, dir) do
    String.contains?(content, " #{dir} ") or
      Enum.any?(String.split(content, "\n"), &mount_line_for?(&1, dir))
  end

  defp mount_line_for?(line, dir) do
    case String.split(line, " ") do
      [_, mount_point | _] -> mount_point == dir
      _ -> false
    end
  end

  defp different_device?(dir) do
    with {:ok, dir_stat} <- File.stat(dir),
         {:ok, root_stat} <- File.stat("/app") do
      dir_stat.major_device != root_stat.major_device or
        dir_stat.minor_device != root_stat.minor_device
    else
      _ -> false
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp dump(backup_dir) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    filename = "alexclaw_backup_#{timestamp}.sql.gz"

    run_pg_dump(System.find_executable("pg_dump"), Path.join(backup_dir, filename), filename)
  end

  defp run_pg_dump(nil, _filepath, _filename), do: {:error, :pg_dump_not_found}

  defp run_pg_dump(pg_dump, filepath, filename) do
    db = db_config()

    args = [
      "-h",
      db.hostname,
      "-U",
      db.username,
      "-d",
      db.database,
      "--no-owner",
      "--no-privileges",
      "--clean",
      "--if-exists"
    ]

    pg_dump
    |> System.cmd(args, env: [{"PGPASSWORD", db.password}], stderr_to_stdout: true)
    |> write_dump(filepath, filename)
  end

  defp write_dump({output, 0}, filepath, filename) do
    case File.write(filepath, :zlib.gzip(output)) do
      :ok -> {:ok, filename}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp write_dump({output, code}, _filepath, _filename),
    do: {:error, {:pg_dump_exit, code, String.slice(output, 0, 500)}}

  @doc """
  Delete all but the `keep` newest backups in `dir` and say what happened:
  the paths deleted and the paths that could not be, with the reason. Only
  names of the form `alexclaw_backup_YYYYMMDD_HHMMSS.sql.gz` are considered.
  """
  @spec rotate(String.t(), non_neg_integer()) ::
          {:ok, %{deleted: [String.t()], failed: [{String.t(), term()}]}}
          | {:error, {:list_failed, term()}}
  def rotate(dir, keep) do
    case File.ls(dir) do
      {:ok, files} -> {:ok, delete_old(dir, files, keep)}
      {:error, reason} -> {:error, {:list_failed, reason}}
    end
  end

  defp delete_old(dir, files, keep) do
    files
    |> Enum.filter(&Regex.match?(~r/^alexclaw_backup_\d{8}_\d{6}\.sql\.gz$/, &1))
    |> Enum.sort(:desc)
    |> Enum.drop(keep)
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.reduce(%{deleted: [], failed: []}, &delete_backup/2)
    |> in_order()
  end

  defp in_order(%{deleted: deleted, failed: failed}),
    do: %{deleted: Enum.reverse(deleted), failed: Enum.reverse(failed)}

  defp delete_backup(path, acc) do
    case File.rm(path) do
      :ok ->
        Logger.info("Rotated old backup: #{Path.basename(path)}", skill: :db_backup)
        %{acc | deleted: [path | acc.deleted]}

      {:error, reason} ->
        Logger.warning("Could not delete old backup #{path}: #{inspect(reason)}",
          skill: :db_backup
        )

        %{acc | failed: [{path, reason} | acc.failed]}
    end
  end

  defp db_config do
    %{
      hostname: System.get_env("DATABASE_HOSTNAME", "db"),
      username: System.get_env("DATABASE_USERNAME", "alexclaw"),
      password: System.get_env("DATABASE_PASSWORD", ""),
      database: "alex_claw_prod"
    }
  end
end
