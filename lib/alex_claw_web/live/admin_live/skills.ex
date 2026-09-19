defmodule AlexClawWeb.AdminLive.Skills do
  @moduledoc "LiveView page listing all registered skills with upload and unload for dynamic skills."

  use Phoenix.LiveView
  require Logger

  alias AlexClaw.Auth.TOTP
  alias AlexClaw.Gateway.Router
  alias AlexClaw.Workflows.SkillRegistry

  @max_upload_size 1_000_000

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AlexClaw.PubSub, "skills:registry")
    end

    {:ok,
     socket
     |> assign(
       page_title: "Skills",
       skills: build_skill_list(),
       running: get_running_skills(),
       uploading: false,
       upload_result: nil,
       pending_2fa: nil
     )
     |> allow_upload(:skill_file,
       # `.ex` has no registered MIME type, so allow_upload/3 refuses it as an
       # accept filter. The filename is enforced server-side in store_upload/2.
       accept: :any,
       max_entries: 1,
       max_file_size: @max_upload_size
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("upload_skill", _params, socket) do
    socket = assign(socket, uploading: true, upload_result: nil)

    result =
      consume_uploaded_entries(socket, :skill_file, fn %{path: tmp_path}, entry ->
        {:ok, store_upload(tmp_path, entry.client_name)}
      end)

    case result do
      [filename] when is_binary(filename) ->
        upload_skill(socket, filename)

      [{:error, :invalid_filename}] ->
        {:noreply,
         socket
         |> put_flash(:error, "Rejected: skill files must be a plain .ex filename")
         |> assign(uploading: false)}

      [] ->
        {:noreply, socket |> put_flash(:error, "No file selected") |> assign(uploading: false)}
    end
  end

  @impl true
  def handle_event("unload_skill", %{"name" => name}, socket) do
    case request_2fa(%{type: :skill_unload, name: name}, "Unload skill: *#{name}*") do
      :challenged ->
        {:noreply,
         socket
         |> assign(pending_2fa: name)
         |> put_flash(:info, "2FA code requested — check Telegram/Discord")}

      :no_2fa ->
        {:noreply,
         put_flash(socket, :error, "2FA must be enabled for skill operations. Set up 2FA first.")}
    end
  end

  @impl true
  def handle_event("reload_skill", %{"name" => name}, socket) do
    case request_2fa(%{type: :skill_reload, name: name}, "Reload skill: *#{name}*") do
      :challenged ->
        {:noreply,
         socket
         |> assign(pending_2fa: name)
         |> put_flash(:info, "2FA code requested — check Telegram/Discord")}

      :no_2fa ->
        {:noreply,
         put_flash(socket, :error, "2FA must be enabled for skill operations. Set up 2FA first.")}
    end
  end

  defp upload_skill(socket, filename) do
    %{type: :skill_load, file_path: filename}
    |> request_2fa("Load skill: `#{filename}`")
    |> uploaded(socket, filename)
  end

  # Staged under skills_dir/pending, never the live directory: until the 2FA code
  # is verified the upload cannot replace a skill that is already loaded.
  defp store_upload(tmp_path, client_name) do
    case SkillRegistry.stage_upload(tmp_path, client_name) do
      {:ok, file_name} ->
        file_name

      {:error, reason} ->
        Logger.warning("Rejected skill upload #{inspect(client_name)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp uploaded(:challenged, socket, filename) do
    {:noreply,
     socket
     |> put_flash(:info, "File uploaded. 2FA code requested — check Telegram/Discord")
     |> assign(uploading: false, pending_2fa: filename)}
  end

  defp uploaded(:no_2fa, socket, _filename) do
    {:noreply,
     socket
     |> put_flash(:error, "2FA must be enabled for skill operations. Set up 2FA first.")
     |> assign(uploading: false)}
  end

  @impl true
  def handle_info({:skill_registered, _name}, socket) do
    {:noreply, assign(socket, skills: build_skill_list(), pending_2fa: nil)}
  end

  def handle_info({:skill_unregistered, _name}, socket) do
    {:noreply, assign(socket, skills: build_skill_list(), pending_2fa: nil)}
  end

  defp request_2fa(action, description) do
    challenge(TOTP.enabled?() && notify_chat_ids(), action, description)
  end

  defp notify_chat_ids do
    Enum.filter(
      [
        AlexClaw.Config.get("telegram.chat_id"),
        AlexClaw.Config.get("discord.channel_id")
      ],
      &(&1 && &1 != "")
    )
  end

  defp challenge(chat_ids, _action, _description) when chat_ids in [false, []], do: :no_2fa

  defp challenge(chat_ids, action, description) do
    for id <- chat_ids, do: TOTP.create_challenge(id, action)

    Router.broadcast(
      "This action requires 2FA verification.\n#{description}\n\nEnter your 6-digit authenticator code:"
    )

    :challenged
  end

  defp build_skill_list do
    Enum.map(SkillRegistry.list_all_with_type(), fn {name, module, type, permissions, routes,
                                                     _ext} ->
      %{
        name: name,
        module: module,
        type: type,
        permissions: permissions,
        routes: routes,
        display_name:
          name
          |> String.replace("_", " ")
          |> String.split(" ")
          |> Enum.map_join(" ", &String.capitalize/1),
        doc: get_description(module),
        version: get_version(module)
      }
    end)
  end

  defp get_running_skills do
    DynamicSupervisor.count_children(AlexClaw.SkillSupervisor).active
  end

  defp get_description(module) do
    if function_exported?(module, :description, 0),
      do: module.description(),
      else: "No description available"
  end

  defp get_version(module) do
    if function_exported?(module, :version, 0), do: module.version(), else: nil
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp upload_error_message(:too_large), do: "File too large (max 1 MB)"
  defp upload_error_message(:not_accepted), do: "Only .ex files accepted"
  defp upload_error_message(err), do: "Error: #{inspect(err)}"
end
