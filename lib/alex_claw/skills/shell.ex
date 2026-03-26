defmodule AlexClaw.Skills.Shell do
  @moduledoc """
  Skill for running whitelisted OS commands inside the container.
  Used for container introspection (disk, memory, connectivity, BEAM diagnostics).

  Security model (5 layers):
  1. 2FA gate — every /shell command requires TOTP when enabled
  2. Whitelist — command must start with an allowed prefix (word-boundary checked)
  3. Blocklist — rejects commands containing shell metacharacters
  4. No shell — System.cmd/3 without shell interpretation, args as list
  5. Timeout + truncation — kill after configurable timeout, cap output
  """
  @behaviour AlexClaw.Skill
  require Logger

  alias AlexClaw.Config

  @default_whitelist ~w[df free ps uptime cat\ /proc ping nslookup curl bin/alex_claw uname whoami hostname date ls git]
  @default_blocklist ["&&", "||", "|", ";", "`", "$(", ">", "<", "\n"]
  @default_timeout_seconds 30
  @default_max_output_chars 4000

  @impl true
  @spec description() :: String.t()
  def description, do: "Execute whitelisted OS commands for container introspection"

  @impl true
  @spec routes() :: [atom()]
  def routes, do: [:on_success, :on_error, :on_timeout]

  @impl true
  @spec run(map()) :: {:ok, String.t(), atom()} | {:error, any()}
  def run(args) do
    if Config.get("shell.enabled") != true do
      {:error, :shell_disabled}
    else
      do_run(args)
    end
  end

  defp do_run(args) do
    config = args[:config] || %{}
    input = args[:input]

    command = config["command"] || to_string(input || "")
    command = String.trim(command)

    if command == "" do
      {:error, :no_command}
    else
      whitelist = load_list(config["whitelist"], "shell.whitelist", @default_whitelist)
      blocklist = load_list(config["blocklist"], "shell.blocklist", @default_blocklist)
      timeout_ms = load_int(config["timeout_seconds"], "shell.timeout_seconds", @default_timeout_seconds) * 1000
      max_chars = load_int(config["max_output_chars"], "shell.max_output_chars", @default_max_output_chars)

      with :ok <- validate_whitelist(command, whitelist),
           :ok <- validate_blocklist(command, blocklist) do
        execute(command, timeout_ms, max_chars)
      end
    end
  end

  # --- Validation ---

  defp validate_whitelist(command, whitelist) do
    if Enum.any?(whitelist, &prefix_matches?(command, &1)) do
      :ok
    else
      {:error, {:not_whitelisted, command}}
    end
  end

  defp validate_blocklist(command, blocklist) do
    found = Enum.find(blocklist, &String.contains?(command, &1))

    if found do
      {:error, {:blocked_metachar, found}}
    else
      :ok
    end
  end

  @doc false
  @spec prefix_matches?(String.t(), String.t()) :: boolean()
  def prefix_matches?(command, prefix) do
    String.starts_with?(command, prefix) and
      (byte_size(command) == byte_size(prefix) or
         String.at(command, String.length(prefix)) in [" ", "/"])
  end

  # --- Execution ---

  defp execute(command, timeout_ms, max_chars) do
    {executable, args} = parse_command(command)

    task =
      Task.async(fn ->
        started = System.monotonic_time(:millisecond)

        try do
          {output, exit_code} = System.cmd(executable, args, stderr_to_stdout: true)
          elapsed = System.monotonic_time(:millisecond) - started
          {output, exit_code, elapsed}
        rescue
          e in ErlangError ->
            elapsed = System.monotonic_time(:millisecond) - started
            {Exception.message(e), 1, elapsed}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code, elapsed}} ->
        result = format_output(command, output, exit_code, elapsed, max_chars)
        branch = if exit_code == 0, do: :on_success, else: :on_error
        {:ok, result, branch}

      nil ->
        {:ok, "$ #{command}\nTimed out after #{div(timeout_ms, 1000)}s", :on_timeout}
    end
  end

  defp parse_command(command) do
    parts = OptionParser.split(command)

    case parts do
      [exe | args] -> {exe, args}
      [] -> {"", []}
    end
  end

  defp format_output(command, output, exit_code, elapsed, max_chars) do
    truncated_output = truncate(output, max_chars)

    marker =
      if String.length(output) > max_chars,
        do: "\n\n[truncated at #{max_chars} chars]",
        else: ""

    "$ #{command}\nExit: #{exit_code} | Time: #{elapsed}ms\n\n#{truncated_output}#{marker}"
  end

  defp truncate(text, max_chars) do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars)
    else
      text
    end
  end

  # --- Config loading ---

  defp load_list(nil, config_key, default) do
    case Config.get(config_key) do
      nil -> default
      val when is_binary(val) -> parse_json_list(val, default)
      _ -> default
    end
  end

  defp load_list(val, _config_key, _default) when is_list(val), do: val

  defp load_list(val, _config_key, default) when is_binary(val) do
    parse_json_list(val, default)
  end

  defp load_list(_, _config_key, default), do: default

  defp parse_json_list(val, default) do
    case Jason.decode(val) do
      {:ok, list} when is_list(list) -> list
      _ -> default
    end
  end

  defp load_int(nil, config_key, default) do
    case Config.get(config_key) do
      nil -> default
      val when is_binary(val) -> String.to_integer(val)
      val when is_integer(val) -> val
      _ -> default
    end
  end

  defp load_int(val, _config_key, _default) when is_integer(val), do: val

  defp load_int(val, _config_key, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp load_int(_, _config_key, default), do: default
end
