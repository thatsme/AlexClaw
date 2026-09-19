defmodule AlexClaw.Dispatcher.AutomationCommands do
  @moduledoc "Handles /record, /replay, /automate web automation commands."

  alias AlexClaw.{Gateway, Message}
  alias AlexClaw.Skills.WebAutomation

  @spec dispatch(Message.t()) :: :ok | term()
  def dispatch(%Message{text: "/record stop " <> session_id} = msg) do
    sid = String.trim(session_id)

    sid
    |> WebAutomation.stop_recording()
    |> recording_stopped(sid, msg)
  end

  def dispatch(%Message{text: "/record start " <> url} = msg) do
    dispatch(%{msg | text: "/record " <> url})
  end

  def dispatch(%Message{text: "/record " <> url} = msg) do
    case WebAutomation.record(%{"url" => String.trim(url)}) do
      {:ok, result, _branch} ->
        sid =
          case Regex.run(~r/Session: `([^`]+)`/, result) do
            [_, id] -> id
            _ -> nil
          end

        stop_hint = if sid, do: "\n\nWhen done, tap: `/record stop #{sid}`", else: ""
        Gateway.send_message(result <> stop_hint, gateway: msg.gateway)

      {:error, :web_automator_disabled} ->
        Gateway.send_message("Web automator is disabled. Enable in Admin > Config.",
          gateway: msg.gateway
        )

      {:error, reason} ->
        Gateway.send_message("Failed to start recording: #{inspect(reason)}",
          gateway: msg.gateway
        )
    end
  end

  def dispatch(%Message{text: "/replay " <> id_str} = msg) do
    id_str
    |> String.trim()
    |> Integer.parse()
    |> replay_parsed(msg)
  end

  def dispatch(%Message{text: "/automate " <> url} = msg) do
    config = %{
      "url" => String.trim(url),
      "steps" => [%{"action" => "scrape"}, %{"action" => "screenshot", "value" => "result"}]
    }

    config
    |> WebAutomation.play([])
    |> automation_played(msg)
  end

  # --- Recording ---

  defp recording_stopped({:error, reason}, _sid, msg) do
    Gateway.send_message("Failed to stop recording: #{inspect(reason)}", gateway: msg.gateway)
  end

  defp recording_stopped({:ok, result}, sid, msg) do
    actions = result["actions"] || []
    summary = result["summary"] || %{}
    base_url = summary["base_url"] || "unknown"
    config = %{"url" => base_url, "steps" => Enum.map(actions, &recorded_step/1)}

    %{name: "Recording #{sid}", type: "automation", url: base_url, metadata: config}
    |> AlexClaw.Resources.create_resource()
    |> recording_saved(length(actions), config, msg)
  end

  defp recorded_step(action) do
    %{
      "action" => action["action_type"],
      "selector" => action["selector"],
      "value" => action["value"],
      "url" => action["url"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp recording_saved({:ok, resource}, count, _config, msg) do
    Gateway.send_message(
      "Recording stopped. #{count} action(s) captured.\n" <>
        "Saved as resource *#{resource.name}* (id: #{resource.id})\n\n" <>
        "Assign this resource to a workflow with the `web_automation` skill to replay it.",
      gateway: msg.gateway
    )
  end

  defp recording_saved({:error, _changeset}, count, config, msg) do
    Gateway.send_message(
      "Recording stopped. #{count} action(s) captured but failed to save as resource.\n\n" <>
        "`#{String.slice(Jason.encode!(config, pretty: true), 0, 3000)}`",
      gateway: msg.gateway
    )
  end

  # --- Replay ---

  defp replay_parsed({id, ""}, msg) do
    AlexClaw.Resources.Resource
    |> AlexClaw.Repo.get(id)
    |> replay_resource(id, msg)
  end

  defp replay_parsed(_parsed, msg) do
    Gateway.send_message("Usage: /replay <resource_id>", gateway: msg.gateway)
  end

  defp replay_resource(nil, id, msg) do
    Gateway.send_message("Resource #{id} not found.", gateway: msg.gateway)
  end

  defp replay_resource(%{type: type} = resource, id, msg) when type != "automation" do
    Gateway.send_message("Resource #{id} is not an automation (type: #{resource.type})",
      gateway: msg.gateway
    )
  end

  defp replay_resource(resource, _id, msg) do
    Gateway.send_message("Replaying *#{resource.name}*...", gateway: msg.gateway)

    resource
    |> replay_config()
    |> WebAutomation.play([])
    |> replay_played(msg)
  end

  # A resource's own url fills in for a config that does not carry one.
  defp replay_config(resource) do
    config = resource.metadata || %{}

    if resource.url && !config["url"],
      do: Map.put(config, "url", resource.url),
      else: config
  end

  # Only the failure wording differs from playback; the rest is shared.
  defp replay_played({:error, reason}, msg) when reason != :web_automator_disabled do
    Gateway.send_message("Replay failed: #{inspect(reason)}", gateway: msg.gateway)
  end

  defp replay_played(result, msg), do: automation_played(result, msg)

  # --- Playback ---

  defp automation_played({:ok, result, _branch}, msg) do
    Gateway.send_message(result, gateway: msg.gateway)
  end

  defp automation_played({:error, :web_automator_disabled}, msg) do
    Gateway.send_message("Web automator is disabled. Enable in Admin > Config.",
      gateway: msg.gateway
    )
  end

  defp automation_played({:error, reason}, msg) do
    Gateway.send_message("Failed: #{inspect(reason)}", gateway: msg.gateway)
  end
end
