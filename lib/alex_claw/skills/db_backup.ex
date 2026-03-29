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
    if Config.get("backup.enabled") == true do
      max_files = Config.get("backup.max_files") || 7

      with :ok <- verify_mount(@backup_dir),
           :ok <- ensure_dir(@backup_dir),
           {:ok, filename} <- dump(@backup_dir),
           rotated <- rotate(@backup_dir, max_files) do
        summary = "Backup saved: #{filename} (rotated #{rotated} old backups)"
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
        Logger.warning("Backup dir #{dir} is NOT a separate mount — backups will be lost on container recreation", skill: :db_backup)
        {:error, {:not_mounted, "#{dir} is on the same filesystem as /app — configure a bind mount in docker-compose.yml"}}

      true ->
        # Dir doesn't exist yet — ensure_dir will create it.
        # Can't verify mount before the dir exists, but if the bind mount is
        # configured in docker-compose.yml, Docker creates the mount point.
        # If it doesn't exist, the mount is likely missing.
        Logger.warning("Backup dir #{dir} does not exist — is the bind mount configured in docker-compose.yml?", skill: :db_backup)
        {:error, {:not_mounted, "#{dir} does not exist — add a bind mount in docker-compose.yml"}}
    end
  end

  defp mount_entry?(dir) do
    case File.read("/proc/mounts") do
      {:ok, content} ->
        String.contains?(content, " #{dir} ") or
          Enum.any?(String.split(content, "\n"), fn line ->
            case String.split(line, " ") do
              [_, mount_point | _] -> mount_point == dir
              _ -> false
            end
          end)

      {:error, _} ->
        false
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
    db = db_config()
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    filename = "alexclaw_backup_#{timestamp}.sql.gz"
    filepath = Path.join(backup_dir, filename)

    pg_dump = System.find_executable("pg_dump")

    if is_nil(pg_dump) do
      {:error, :pg_dump_not_found}
    else
      args = [
        "-h", db.hostname,
        "-U", db.username,
        "-d", db.database,
        "--no-owner",
        "--no-privileges",
        "--clean",
        "--if-exists"
      ]

      env = [{"PGPASSWORD", db.password}]

      case System.cmd(pg_dump, args, env: env, stderr_to_stdout: true) do
        {output, 0} ->
          compressed = :zlib.gzip(output)

          case File.write(filepath, compressed) do
            :ok -> {:ok, filename}
            {:error, reason} -> {:error, {:write_failed, reason}}
          end

        {output, code} ->
          {:error, {:pg_dump_exit, code, String.slice(output, 0, 500)}}
      end
    end
  end

  defp rotate(backup_dir, max_files) do
    case File.ls(backup_dir) do
      {:ok, files} ->
        backups =
          files
          |> Enum.filter(&String.starts_with?(&1, "alexclaw_backup_"))
          |> Enum.sort(:desc)

        to_delete = Enum.drop(backups, max_files)

        Enum.each(to_delete, fn file ->
          path = Path.join(backup_dir, file)
          File.rm(path)
          Logger.info("Rotated old backup: #{file}", skill: :db_backup)
        end)

        length(to_delete)

      {:error, _} ->
        0
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
