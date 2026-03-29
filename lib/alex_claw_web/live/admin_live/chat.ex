defmodule AlexClawWeb.AdminLive.Chat do
  @moduledoc "Interactive conversational chat with LLM provider selection."

  use Phoenix.LiveView

  alias AlexClaw.{Identity, LLM, Memory}

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Chat",
       messages: [],
       loading: false,
       provider: "auto",
       providers: LLM.list_provider_choices()
     )}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("send", %{"message" => message}, socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, socket}
    else
      user_msg = %{role: :user, content: message, timestamp: DateTime.utc_now()}
      messages = socket.assigns.messages ++ [user_msg]
      provider = socket.assigns.provider

      socket =
        socket
        |> assign(messages: messages, loading: true)
        |> start_async(:llm_response, fn -> generate_response(message, provider) end)

      {:noreply, socket}
    end
  end

  def handle_event("set_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, provider: provider)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, messages: [])}
  end

  @impl true
  @spec handle_async(atom(), {:ok, term()} | {:exit, term()}, Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async(:llm_response, {:ok, {:error, reason}}, socket) do
    error_msg = %{role: :system, content: "Error: #{inspect(reason)}", timestamp: DateTime.utc_now()}
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [error_msg], loading: false)}
  end

  def handle_async(:llm_response, {:ok, response}, socket) when is_binary(response) do
    ai_msg = %{role: :assistant, content: response, timestamp: DateTime.utc_now()}
    messages = socket.assigns.messages ++ [ai_msg]

    user_msg = List.last(Enum.filter(socket.assigns.messages, &(&1.role == :user)))

    if user_msg do
      Memory.store(:conversation, "User: #{user_msg.content}", source: "web_chat")
      Memory.store(:conversation, "AlexClaw: #{response}", source: "web_chat")
    end

    {:noreply, assign(socket, messages: messages, loading: false)}
  end

  def handle_async(:llm_response, {:exit, reason}, socket) do
    error_msg = %{role: :system, content: "Request failed: #{inspect(reason)}", timestamp: DateTime.utc_now()}
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [error_msg], loading: false)}
  end

  @spec generate_response(String.t(), String.t()) :: String.t() | {:error, term()}
  defp generate_response(query, provider) do
    system = Identity.system_prompt(%{skill: :conversational})

    recent =
      case Memory.recent(kind: :conversation, limit: 6) do
        [] ->
          ""

        entries ->
          history =
            entries
            |> Enum.reverse()
            |> Enum.map_join("\n", & &1.content)

          "\n\nRecent conversation:\n#{history}"
      end

    prompt = "#{recent}\n\nUser: #{query}"

    opts =
      case provider do
        "auto" -> [tier: :light]
        name -> [provider: name]
      end

    case LLM.complete(prompt, opts ++ [system: system]) do
      {:ok, response} -> response
      {:error, reason} -> {:error, reason}
    end
  end
end
