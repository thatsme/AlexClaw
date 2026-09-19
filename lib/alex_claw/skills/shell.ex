defmodule AlexClaw.Skills.Shell do
  @moduledoc """
  Skill for running whitelisted OS commands inside the container.
  Used for container introspection (disk, memory, connectivity, BEAM diagnostics).

  Security model (5 layers):
  1. 2FA gate — every /shell command requires TOTP, and is refused when TOTP is off
  2. Allowlist — command must match an exact entry, or start with an allowed prefix
     (word-boundary checked)
  3. Blocklist — rejects commands containing shell metacharacters
  4. No shell — System.cmd/3 without shell interpretation, args as list
  5. Timeout + truncation — kill after configurable timeout, cap output

  The allowlist, blocklist and exact-command list are read from Config or the
  compiled defaults only. A workflow step supplies a command, never the limits it
  is checked against; it may narrow the timeout and output cap but never widen them.
  """
  @behaviour AlexClaw.Skill
  require Logger

  alias AlexClaw.Config

  @default_whitelist ~w[df free uptime uname whoami hostname date ls]
  @default_exact_commands ["cat /proc/meminfo", "cat /proc/loadavg", "ps aux"]
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
  @spec step_fields() :: [atom()]
  def step_fields, do: [:config]

  @impl true
  @spec config_hint() :: String.t()
  def config_hint, do: ~s|{"command": "df -h"}|

  @impl true
  @spec config_scaffold() :: map()
  def config_scaffold, do: %{"command" => "df -h"}

  @impl true
  @spec config_presets() :: %{String.t() => map()}
  def config_presets do
    %{
      "Memory" => %{"command" => "free -m"},
      "Disk" => %{"command" => "df -h"},
      "Processes" => %{"command" => "ps aux"},
      "Uptime" => %{"command" => "uptime"},
      "Memory detail" => %{"command" => "cat /proc/meminfo"}
    }
  end

  @impl true
  @spec config_help() :: String.t()
  def config_help,
    do:
      "command: the OS command to execute. Must match an allowed prefix (df, free, uptime, uname, whoami, hostname, date, ls) or an exact allowed command such as 'ps aux'. Shell metacharacters (pipes, redirects, semicolons) are blocked. The allowlist is set in Config, not here; timeout_seconds and max_output_chars may only lower the configured limits."

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
    command = String.trim(config["command"] || to_string(args[:input] || ""))

    execute_allowed(command, args_timeout_ms(config), args_max_chars(config))
  end

  defp execute_allowed("", _timeout_ms, _max_chars), do: {:error, :no_command}

  defp execute_allowed(command, timeout_ms, max_chars) do
    with :ok <- validate_allowed(command),
         :ok <-
           validate_blocklist(command, configured_list("shell.blocklist", @default_blocklist)) do
      execute(command, timeout_ms, max_chars)
    end
  end

  # A step may narrow the limits but never widen them.
  defp args_timeout_ms(config) do
    ceiling = configured_int("shell.timeout_seconds", @default_timeout_seconds) * 1000

    case load_int(config["timeout_seconds"]) do
      nil -> ceiling
      seconds -> min(seconds * 1000, ceiling)
    end
  end

  defp args_max_chars(config) do
    ceiling = configured_int("shell.max_output_chars", @default_max_output_chars)

    case load_int(config["max_output_chars"]) do
      nil -> ceiling
      chars -> min(chars, ceiling)
    end
  end

  # --- Validation ---

  defp validate_allowed(command) do
    if exact_allowed?(command) or prefix_allowed?(command) do
      :ok
    else
      {:error, {:not_whitelisted, command}}
    end
  end

  # Exact entries are compared byte-for-byte: "cat /proc/meminfo x" is not "cat /proc/meminfo".
  defp exact_allowed?(command) do
    command in configured_list("shell.exact_commands", @default_exact_commands)
  end

  defp prefix_allowed?(command) do
    Enum.any?(
      configured_list("shell.whitelist", @default_whitelist),
      &prefix_matches?(command, &1)
    )
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

  # Lists come from Config or the compiled defaults only. A caller-supplied list would
  # let the step redefine the very limits it is being checked against.
  defp configured_list(config_key, default) do
    case Config.get(config_key) do
      val when is_list(val) -> val
      val when is_binary(val) -> parse_json_list(val, default)
      _ -> default
    end
  end

  defp parse_json_list(val, default) do
    case Jason.decode(val) do
      {:ok, list} when is_list(list) -> list
      _ -> default
    end
  end

  defp configured_int(config_key, default) do
    case Config.get(config_key) do
      val when is_integer(val) -> val
      val when is_binary(val) -> load_int(val) || default
      _ -> default
    end
  end

  # nil means "the step did not ask". A non-positive value is treated the same way:
  # a negative timeout crashes Task.yield/2 and a negative cap crashes String.slice/3.
  defp load_int(nil), do: nil
  defp load_int(val) when is_integer(val) and val > 0, do: val
  defp load_int(val) when is_integer(val), do: nil

  defp load_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp load_int(_val), do: nil
end
