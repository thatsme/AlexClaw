defmodule AlexClaw.Dispatcher.SkillCommands do
  @moduledoc """
  Handles /skill load|unload|reload|create|list commands.

  SECURITY: load, unload and reload always require 2FA verification, and are
  refused outright when 2FA is not configured. Loading code into a running BEAM
  is the most dangerous operation in the system.

  The verified action is carried out by `AuthCommands.execute_2fa_action/2`, so
  this module only raises the challenge — it never performs the operation itself.
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
      :no_2fa -> require_2fa_message(msg)
    end
  end

  def dispatch(%Message{text: "/skill unload " <> name} = msg) do
    case AuthCommands.require_2fa(
           msg,
           %{type: :skill_unload, name: String.trim(name)},
           "Unload skill: *#{String.trim(name)}*"
         ) do
      :challenged -> :ok
      :no_2fa -> require_2fa_message(msg)
    end
  end

  def dispatch(%Message{text: "/skill reload " <> name} = msg) do
    case AuthCommands.require_2fa(
           msg,
           %{type: :skill_reload, name: String.trim(name)},
           "Reload skill: *#{String.trim(name)}*"
         ) do
      :challenged -> :ok
      :no_2fa -> require_2fa_message(msg)
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

  # Skill operations load code into the running VM, so they are refused outright
  # when there is no second factor — the same posture as the Skills admin page.
  defp require_2fa_message(msg) do
    Gateway.send_message("Enable 2FA first: /setup 2fa", gateway: msg.gateway)
  end
end
