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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-[calc(100vh-8rem)]">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h1 class="text-xl font-bold text-white">Chat</h1>
          <p class="text-xs text-gray-500 mt-1">
            Conversation with semantic memory context
            <%= if @memory_hits > 0 do %>
              — <span class="text-claw-500">{@memory_hits} memory matches</span> on last query
            <% end %>
          </p>
        </div>
        <div class="flex items-center gap-3">
          <form phx-change="set_provider">
            <select
              name="provider"
              class="bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-xs text-gray-300"
            >
              <option
                :for={p <- @providers}
                value={p.value}
                selected={@provider == p.value}
              >
                {p.label}
              </option>
            </select>
          </form>
          <button
            :if={@messages != []}
            phx-click="clear"
            class="px-3 py-1.5 text-xs text-gray-400 hover:text-white bg-gray-800 hover:bg-gray-700 rounded transition"
          >
            Clear
          </button>
        </div>
      </div>

      <div
        class="flex-1 overflow-y-auto bg-gray-900 rounded-lg border border-gray-800 p-4 space-y-4"
        id="chat-messages"
      >
        <div :if={@messages == []} class="flex items-center justify-center h-full">
          <div class="text-center text-gray-500">
            <p class="text-lg mb-2">Ask anything.</p>
            <p class="text-xs">
              Responses are enriched with semantic search across all stored memories — news, CVEs, research, conversations.
            </p>
          </div>
        </div>

        <div :for={msg <- @messages} class={["flex", msg.role == :user && "justify-end"]}>
          <div class={[
            "max-w-[75%] rounded-lg px-4 py-3 text-sm",
            msg.role == :user && "bg-claw-800 text-white",
            msg.role == :assistant && "bg-gray-800 text-gray-100",
            msg.role == :system && "bg-red-900/30 text-red-300 border border-red-800"
          ]}>
            <div class="whitespace-pre-wrap break-words">{msg.content}</div>
            <div class="text-xs text-gray-500 mt-1">
              {Calendar.strftime(msg.timestamp, "%H:%M")}
            </div>
          </div>
        </div>

        <div :if={@loading} class="flex">
          <div class="bg-gray-800 rounded-lg px-4 py-3 text-sm text-gray-400 animate-pulse">
            Thinking...
          </div>
        </div>
      </div>

      <form phx-submit="send" class="mt-4 flex gap-3">
        <input
          type="text"
          name="message"
          placeholder="Ask about CVEs, security alerts, or anything in memory..."
          autocomplete="off"
          disabled={@loading}
          phx-debounce="100"
          class="flex-1 bg-gray-800 border border-gray-700 rounded-lg px-4 py-3 text-white text-sm focus:border-claw-500 focus:outline-none disabled:opacity-50"
        />
        <button
          type="submit"
          disabled={@loading}
          class="px-6 py-3 bg-claw-700 hover:bg-claw-600 disabled:bg-gray-700 text-white text-sm rounded-lg transition"
        >
          Send
        </button>
      </form>
    </div>
    """
  end
end
