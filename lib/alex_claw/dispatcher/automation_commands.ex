defmodule AlexClaw.Dispatcher.AutomationCommands do
  @moduledoc "Handles /record, /replay, /automate web automation commands."

  alias AlexClaw.{Gateway, Message}

  @spec dispatch(Message.t()) :: :ok | term()
  def dispatch(%Message{text: "/record stop " <> session_id} = msg) do
    sid = String.trim(session_id)
    case AlexClaw.Skills.WebAutomation.stop_recording(sid) do
      {:ok, result} ->
        actions = result["actions"] || []
        summary = result["summary"] || %{}
        base_url = summary["base_url"] || "unknown"

        steps = actions |> Enum.map(fn a ->
          %{"action" => a["action_type"], "selector" => a["selector"], "value" => a["value"], "url" => a["url"]}
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
        end)

        config = %{"url" => base_url, "steps" => steps}

        case AlexClaw.Resources.create_resource(%{
          name: "Recording #{sid}",
          type: "automation",
          url: base_url,
          metadata: config
        }) do
          {:ok, resource} ->
            Gateway.send_message(
              "Recording stopped. #{length(actions)} action(s) captured.\n" <>
              "Saved as resource *#{resource.name}* (id: #{resource.id})\n\n" <>
              "Assign this resource to a workflow with the `web_automation` skill to replay it.",
              gateway: msg.gateway
            )
          {:error, _changeset} ->
            Gateway.send_message(
              "Recording stopped. #{length(actions)} action(s) captured but failed to save as resource.\n\n" <>
              "`#{Jason.encode!(config, pretty: true) |> String.slice(0, 3000)}`",
              gateway: msg.gateway
            )
        end
      {:error, reason} ->
        Gateway.send_message("Failed to stop recording: #{inspect(reason)}", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/record start " <> url} = msg) do
    dispatch(%{msg | text: "/record " <> url})
  end

  def dispatch(%Message{text: "/record " <> url} = msg) do
    case AlexClaw.Skills.WebAutomation.record(%{"url" => String.trim(url)}) do
      {:ok, result, _branch} ->
        sid = case Regex.run(~r/Session: `([^`]+)`/, result) do
          [_, id] -> id
          _ -> nil
        end
        stop_hint = if sid, do: "\n\nWhen done, tap: `/record stop #{sid}`", else: ""
        Gateway.send_message(result <> stop_hint, gateway: msg.gateway)
      {:error, :web_automator_disabled} -> Gateway.send_message("Web automator is disabled. Enable in Admin > Config.", gateway: msg.gateway)
      {:error, reason} -> Gateway.send_message("Failed to start recording: #{inspect(reason)}", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/replay " <> id_str} = msg) do
    case id_str |> String.trim() |> Integer.parse() do
      {id, ""} ->
        case AlexClaw.Repo.get(AlexClaw.Resources.Resource, id) do
          nil ->
            Gateway.send_message("Resource #{id} not found.", gateway: msg.gateway)

          resource when resource.type != "automation" ->
            Gateway.send_message("Resource #{id} is not an automation (type: #{resource.type})", gateway: msg.gateway)

          resource ->
            config = resource.metadata || %{}
            config = if resource.url && !config["url"], do: Map.put(config, "url", resource.url), else: config
            Gateway.send_message("Replaying *#{resource.name}*...", gateway: msg.gateway)

            case AlexClaw.Skills.WebAutomation.play(config, []) do
              {:ok, result, _branch} -> Gateway.send_message(result, gateway: msg.gateway)
              {:error, :web_automator_disabled} -> Gateway.send_message("Web automator is disabled. Enable in Admin > Config.", gateway: msg.gateway)
              {:error, reason} -> Gateway.send_message("Replay failed: #{inspect(reason)}", gateway: msg.gateway)
            end
        end

      _ ->
        Gateway.send_message("Usage: /replay <resource_id>", gateway: msg.gateway)
    end
  end

  def dispatch(%Message{text: "/automate " <> url} = msg) do
    config = %{"url" => String.trim(url), "steps" => [%{"action" => "scrape"}, %{"action" => "screenshot", "value" => "result"}]}
    case AlexClaw.Skills.WebAutomation.play(config, []) do
      {:ok, result, _branch} -> Gateway.send_message(result, gateway: msg.gateway)
      {:error, :web_automator_disabled} -> Gateway.send_message("Web automator is disabled. Enable in Admin > Config.", gateway: msg.gateway)
      {:error, reason} -> Gateway.send_message("Failed: #{inspect(reason)}", gateway: msg.gateway)
    end
  end
end
