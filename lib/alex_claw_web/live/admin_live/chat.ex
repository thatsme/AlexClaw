defmodule AlexClawWeb.AdminLive.Chat do
  @moduledoc "Interactive chat with memory-backed semantic search context."

  use Phoenix.LiveView

  alias AlexClaw.{Identity, LLM, Memory}

  @impl true
  def mount(_params, _session, socket) do
    providers = LLM.list_provider_choices()

    {:ok,
     assign(socket,
       page_title: "Chat",
       messages: [],
       loading: false,
       memory_hits: 0,
       provider: "auto",
       providers: providers
     )}
  end

  @impl true
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
    {:noreply, assign(socket, messages: [], memory_hits: 0)}
  end

  @impl true
  def handle_async(:llm_response, {:ok, {:error, reason}}, socket) do
    error_msg = %{
      role: :system,
      content: "Error: #{inspect(reason)}",
      timestamp: DateTime.utc_now()
    }

    messages = socket.assigns.messages ++ [error_msg]
    {:noreply, assign(socket, messages: messages, loading: false)}
  end

  def handle_async(:llm_response, {:ok, {response, memory_count}}, socket) do
    ai_msg = %{role: :assistant, content: response, timestamp: DateTime.utc_now()}
    messages = socket.assigns.messages ++ [ai_msg]

    user_msg = List.last(Enum.filter(socket.assigns.messages, &(&1.role == :user)))

    if user_msg do
      Memory.store(:conversation, "User: #{user_msg.content}", source: "web_chat")
      Memory.store(:conversation, "AlexClaw: #{response}", source: "web_chat")
    end

    {:noreply, assign(socket, messages: messages, loading: false, memory_hits: memory_count)}
  end

  def handle_async(:llm_response, {:exit, reason}, socket) do
    error_msg = %{
      role: :system,
      content: "Request failed: #{inspect(reason)}",
      timestamp: DateTime.utc_now()
    }

    messages = socket.assigns.messages ++ [error_msg]
    {:noreply, assign(socket, messages: messages, loading: false)}
  end

  defp generate_response(query, provider) do
    system = Identity.system_prompt(%{skill: :conversational})

    memory_results = Memory.search(query, limit: 5)

    memory_context =
      case memory_results do
        [] ->
          ""

        entries ->
          context =
            entries
            |> Enum.map_join("\n---\n", fn e ->
              kind_label = String.upcase(e.kind)
              "[#{kind_label}] #{String.slice(e.content, 0, 500)}"
            end)

          "\n\nRelevant knowledge from memory:\n#{context}"
      end

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

    prompt = "#{memory_context}#{recent}\n\nUser: #{query}"

    opts =
      case provider do
        "auto" -> [tier: :light]
        name -> [provider: name]
      end

    case LLM.complete(prompt, opts ++ [system: system]) do
      {:ok, response} -> {response, length(memory_results)}
      {:error, reason} -> {:error, reason}
    end
  end

end
