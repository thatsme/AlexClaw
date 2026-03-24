defmodule AlexClaw.Dispatcher.SkillCommands do
  @moduledoc "Handles /skill load|unload|reload|create|list commands."

  alias AlexClaw.{Gateway, Message}

  @spec dispatch(Message.t()) :: :ok | term()
  def dispatch(%Message{text: "/skill load " <> file_path} = msg) do
    case AlexClaw.Workflows.SkillRegistry.load_skill(String.trim(file_path)) do
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

      {:error, reason} ->
        Gateway.send_message("Failed to load skill: #{inspect(reason)}", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/skill unload " <> name} = msg) do
    case AlexClaw.Workflows.SkillRegistry.unload_skill(String.trim(name)) do
      :ok -> Gateway.send_message("Skill *#{String.trim(name)}* unloaded.", gateway: msg.gateway)
      {:error, :cannot_unload_core} -> Gateway.send_message("Cannot unload core skills.", gateway: msg.gateway)
      {:error, :not_found} -> Gateway.send_message("Skill not found: `#{String.trim(name)}`", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/skill reload " <> name} = msg) do
    case AlexClaw.Workflows.SkillRegistry.reload_skill(String.trim(name)) do
      {:ok, %{name: n, permissions: perms}} ->
        perm_list = Enum.map_join(perms, ", ", &to_string/1)
        Gateway.send_message("Skill *#{n}* reloaded. Permissions: [#{perm_list}]", gateway: msg.gateway)

      {:error, :not_found} ->
        Gateway.send_message("Skill not found: `#{String.trim(name)}`", gateway: msg.gateway)

      {:error, reason} ->
        Gateway.send_message("Failed to reload: #{inspect(reason)}", gateway: msg.gateway)
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
    /skill load <filename> — compile and register a skill
    /skill unload <name> — remove a dynamic skill
    /skill reload <name> — recompile from stored path
    /skill create <name> — generate template in skills dir
    /skill list — list all skills with type
    """, gateway: msg.gateway)
  end
end
