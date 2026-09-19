defmodule AlexClaw.Dispatcher.SkillCommands do
  @moduledoc """
  Handles /skill load|unload|reload|create|list commands.

  SECURITY: load, unload, and reload ALWAYS require 2FA verification.
  Loading code into a running BEAM is the most dangerous operation
  in the system — no exceptions, no config toggle.
  """

  alias AlexClaw.Dispatcher.AuthCommands
  alias AlexClaw.Gateway
  alias AlexClaw.Message
  alias AlexClaw.Workflows.SkillRegistry

  @spec dispatch(Message.t()) :: :ok | term()
  def dispatch(%Message{text: "/skill load " <> file_path} = msg) do
    case AuthCommands.require_2fa(
           msg,
           %{type: :skill_load, file_path: String.trim(file_path)},
           "Load skill: `#{String.trim(file_path)}`"
         ) do
      :challenged -> :ok
      :proceed -> do_load(String.trim(file_path), msg)
    end
  end

  def dispatch(%Message{text: "/skill unload " <> name} = msg) do
    case AuthCommands.require_2fa(
           msg,
           %{type: :skill_unload, name: String.trim(name)},
           "Unload skill: *#{String.trim(name)}*"
         ) do
      :challenged -> :ok
      :proceed -> do_unload(String.trim(name), msg)
    end
  end

  def dispatch(%Message{text: "/skill reload " <> name} = msg) do
    case AuthCommands.require_2fa(
           msg,
           %{type: :skill_reload, name: String.trim(name)},
           "Reload skill: *#{String.trim(name)}*"
         ) do
      :challenged -> :ok
      :proceed -> do_reload(String.trim(name), msg)
    end
  end

  def dispatch(%Message{text: "/skill create " <> name} = msg) do
    case SkillRegistry.create_skill(String.trim(name)) do
      {:ok, file_name} ->
        Gateway.send_message(
          "Template created: `#{file_name}`\n" <>
            "Edit the file, then load with: `/skill load #{file_name}`",
          gateway: msg.gateway
        )

      {:error, :already_exists} ->
        Gateway.send_message("File already exists for skill `#{String.trim(name)}`.",
          gateway: msg.gateway
        )
    end
  end

  def dispatch(%Message{text: "/skill list" <> _} = msg) do
    AlexClaw.Dispatcher.dispatch(%{msg | text: "/skills"})
  end

  def dispatch(%Message{text: "/skill" <> _} = msg) do
    Gateway.send_message(
      """
      *Skill plugin commands*
      /skill load <filename> — compile and register a skill (2FA required)
      /skill unload <name> — remove a dynamic skill (2FA required)
      /skill reload <name> — recompile from stored path (2FA required)
      /skill create <name> — generate template in skills dir
      /skill list — list all skills with type
      """,
      gateway: msg.gateway
    )
  end

  # --- Execution (post-2FA) ---
  # Public so AuthCommands.execute_2fa_action can call after verification.

  @doc false
  @spec do_load_after_2fa(String.t(), Message.t()) :: :ok
  def do_load_after_2fa(file_path, msg), do: do_load(file_path, msg)

  @doc false
  @spec do_unload_after_2fa(String.t(), Message.t()) :: :ok
  def do_unload_after_2fa(name, msg), do: do_unload(name, msg)

  @doc false
  @spec do_reload_after_2fa(String.t(), Message.t()) :: :ok
  def do_reload_after_2fa(name, msg), do: do_reload(name, msg)

  defp do_load(file_path, msg) do
    file_path
    |> SkillRegistry.load_skill()
    |> load_message()
    |> Gateway.send_message(gateway: msg.gateway)
  end

  defp load_message({:ok, %{name: name, permissions: perms}}) do
    "Skill *#{name}* loaded. Permissions: [#{Enum.map_join(perms, ", ", &to_string/1)}]"
  end

  defp load_message({:error, :path_traversal}),
    do: "Error: file must be inside the skills directory."

  defp load_message({:error, :file_not_found}), do: "Error: file not found."

  defp load_message({:error, {:invalid_namespace, ns}}),
    do: "Error: module must be under `AlexClaw.Skills.Dynamic.*`, got `#{ns}`"

  defp load_message({:error, :missing_run_callback}), do: "Error: module must export `run/1`."

  defp load_message({:error, {:unknown_permissions, invalid}}),
    do: "Error: unknown permissions: #{inspect(invalid)}"

  defp load_message({:error, :name_conflicts_with_core}),
    do: "Error: name conflicts with a core skill."

  defp load_message({:error, {:compilation_error, err_msg}}),
    do: "Compilation error:\n`#{String.slice(err_msg, 0, 500)}`"

  defp load_message({:error, {:same_version, nil, _hint}}),
    do:
      "Error: skill already loaded with no version. Add `def version, do: \"1.0.0\"` and bump it before loading. Use `/skill reload` to force."

  defp load_message({:error, {:same_version, ver, _hint}}),
    do:
      "Error: version *#{ver}* already loaded. Bump the version before loading. Use `/skill reload` to force."

  defp load_message({:error, reason}), do: "Failed to load skill: #{inspect(reason)}"

  defp do_unload(name, msg) do
    case SkillRegistry.unload_skill(name) do
      :ok ->
        Gateway.send_message("Skill *#{name}* unloaded.", gateway: msg.gateway)

      {:error, :cannot_unload_core} ->
        Gateway.send_message("Cannot unload core skills.", gateway: msg.gateway)

      {:error, :not_found} ->
        Gateway.send_message("Skill not found: `#{name}`", gateway: msg.gateway)
    end
  end

  defp do_reload(name, msg) do
    case SkillRegistry.reload_skill(name) do
      {:ok, %{name: n, permissions: perms}} ->
        perm_list = Enum.map_join(perms, ", ", &to_string/1)

        Gateway.send_message("Skill *#{n}* reloaded. Permissions: [#{perm_list}]",
          gateway: msg.gateway
        )

      {:error, :not_found} ->
        Gateway.send_message("Skill not found: `#{name}`", gateway: msg.gateway)

      {:error, reason} ->
        Gateway.send_message("Failed to reload: #{inspect(reason)}", gateway: msg.gateway)
    end
  end
end
