defmodule AlexClaw.Dispatcher.SkillCommands do
  @moduledoc """
  Handles /skill load|unload|reload|create|list commands.

  SECURITY: load, unload, and reload ALWAYS require 2FA verification.
  Loading code into a running BEAM is the most dangerous operation
  in the system — no exceptions, no config toggle.
  """

  alias AlexClaw.{Gateway, Message}
  alias AlexClaw.Dispatcher.AuthCommands

  @spec dispatch(Message.t()) :: :ok | term()
  def dispatch(%Message{text: "/skill load " <> file_path} = msg) do
    case AuthCommands.require_2fa(msg, %{type: :skill_load, file_path: String.trim(file_path)},
           "Load skill: `#{String.trim(file_path)}`") do
      :challenged -> :ok
      :proceed -> do_load(String.trim(file_path), msg)
    end
  end

  def dispatch(%Message{text: "/skill unload " <> name} = msg) do
    case AuthCommands.require_2fa(msg, %{type: :skill_unload, name: String.trim(name)},
           "Unload skill: *#{String.trim(name)}*") do
      :challenged -> :ok
      :proceed -> do_unload(String.trim(name), msg)
    end
  end

  def dispatch(%Message{text: "/skill reload " <> name} = msg) do
    case AuthCommands.require_2fa(msg, %{type: :skill_reload, name: String.trim(name)},
           "Reload skill: *#{String.trim(name)}*") do
      :challenged -> :ok
      :proceed -> do_reload(String.trim(name), msg)
    end
  end

  def dispatch(%Message{text: "/skill create " <> name} = msg) do
    case AlexClaw.Workflows.SkillRegistry.create_skill(String.trim(name)) do
      {:ok, file_name} ->
        Gateway.send_message(
          "Template created: `#{file_name}`\n" <>
          "Edit the file, then load with: `/skill load #{file_name}`",
          gateway: msg.gateway
        )

      {:error, :already_exists} ->
        Gateway.send_message("File already exists for skill `#{String.trim(name)}`.", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/skill list" <> _} = msg) do
    AlexClaw.Dispatcher.dispatch(%{msg | text: "/skills"})
  end

  def dispatch(%Message{text: "/skill" <> _} = msg) do
    Gateway.send_message("""
    *Skill plugin commands*
    /skill load <filename> — compile and register a skill (2FA required)
    /skill unload <name> — remove a dynamic skill (2FA required)
    /skill reload <name> — recompile from stored path (2FA required)
    /skill create <name> — generate template in skills dir
    /skill list — list all skills with type
    """, gateway: msg.gateway)
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
    case AlexClaw.Workflows.SkillRegistry.load_skill(file_path) do
      {:ok, %{name: name, permissions: perms}} ->
        perm_list = Enum.map_join(perms, ", ", &to_string/1)
        Gateway.send_message("Skill *#{name}* loaded. Permissions: [#{perm_list}]", gateway: msg.gateway)

      {:error, :path_traversal} ->
        Gateway.send_message("Error: file must be inside the skills directory.", gateway: msg.gateway)

      {:error, :file_not_found} ->
        Gateway.send_message("Error: file not found.", gateway: msg.gateway)

      {:error, {:invalid_namespace, ns}} ->
        Gateway.send_message("Error: module must be under `AlexClaw.Skills.Dynamic.*`, got `#{ns}`", gateway: msg.gateway)

      {:error, :missing_run_callback} ->
        Gateway.send_message("Error: module must export `run/1`.", gateway: msg.gateway)

      {:error, {:unknown_permissions, invalid}} ->
        Gateway.send_message("Error: unknown permissions: #{inspect(invalid)}", gateway: msg.gateway)

      {:error, :name_conflicts_with_core} ->
        Gateway.send_message("Error: name conflicts with a core skill.", gateway: msg.gateway)

      {:error, {:compilation_error, err_msg}} ->
        Gateway.send_message("Compilation error:\n`#{String.slice(err_msg, 0, 500)}`", gateway: msg.gateway)

      {:error, {:same_version, nil, _hint}} ->
        Gateway.send_message("Error: skill already loaded with no version. Add `def version, do: \"1.0.0\"` and bump it before loading. Use `/skill reload` to force.", gateway: msg.gateway)

      {:error, {:same_version, ver, _hint}} ->
        Gateway.send_message("Error: version *#{ver}* already loaded. Bump the version before loading. Use `/skill reload` to force.", gateway: msg.gateway)

      {:error, reason} ->
        Gateway.send_message("Failed to load skill: #{inspect(reason)}", gateway: msg.gateway)
    end
  end

  defp do_unload(name, msg) do
    case AlexClaw.Workflows.SkillRegistry.unload_skill(name) do
      :ok -> Gateway.send_message("Skill *#{name}* unloaded.", gateway: msg.gateway)
      {:error, :cannot_unload_core} -> Gateway.send_message("Cannot unload core skills.", gateway: msg.gateway)
      {:error, :not_found} -> Gateway.send_message("Skill not found: `#{name}`", gateway: msg.gateway)
    end
  end

  defp do_reload(name, msg) do
    case AlexClaw.Workflows.SkillRegistry.reload_skill(name) do
      {:ok, %{name: n, permissions: perms}} ->
        perm_list = Enum.map_join(perms, ", ", &to_string/1)
        Gateway.send_message("Skill *#{n}* reloaded. Permissions: [#{perm_list}]", gateway: msg.gateway)

      {:error, :not_found} ->
        Gateway.send_message("Skill not found: `#{name}`", gateway: msg.gateway)

      {:error, reason} ->
        Gateway.send_message("Failed to reload: #{inspect(reason)}", gateway: msg.gateway)
    end
  end
end
