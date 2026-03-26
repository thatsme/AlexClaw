defmodule AlexClawWeb.AdminLive.Chat do
  @moduledoc "Interactive chat with memory and knowledge base RAG context."

  use Phoenix.LiveView

  alias AlexClaw.{Identity, Knowledge, LLM, Memory}

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    providers = LLM.list_provider_choices()

    {:ok,
     assign(socket,
       page_title: "Chat",
       messages: [],
       loading: false,
       memory_hits: 0,
       knowledge_hits: 0,
       context_source: "both",
       provider: "auto",
       providers: providers
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
      context_source = socket.assigns.context_source

      socket =
        socket
        |> assign(messages: messages, loading: true)
        |> start_async(:llm_response, fn -> generate_response(message, provider, context_source) end)

      {:noreply, socket}
    end
  end

  def handle_event("set_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, provider: provider)}
  end

  def handle_event("set_context", %{"context_source" => source}, socket) do
    {:noreply, assign(socket, context_source: source)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, messages: [], memory_hits: 0, knowledge_hits: 0)}
  end

  @impl true
  @spec handle_async(atom(), {:ok, term()} | {:exit, term()}, Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async(:llm_response, {:ok, {:error, reason}}, socket) do
    error_msg = %{
      role: :system,
      content: "Error: #{inspect(reason)}",
      timestamp: DateTime.utc_now()
    }

    messages = socket.assigns.messages ++ [error_msg]
    {:noreply, assign(socket, messages: messages, loading: false)}
  end

  def handle_async(:llm_response, {:ok, {response, memory_count, knowledge_count}}, socket) do
    ai_msg = %{role: :assistant, content: response, timestamp: DateTime.utc_now()}
    messages = socket.assigns.messages ++ [ai_msg]

    user_msg = List.last(Enum.filter(socket.assigns.messages, &(&1.role == :user)))

    if user_msg do
      Memory.store(:conversation, "User: #{user_msg.content}", source: "web_chat")
      Memory.store(:conversation, "AlexClaw: #{response}", source: "web_chat")
    end

    {:noreply, assign(socket, messages: messages, loading: false, memory_hits: memory_count, knowledge_hits: knowledge_count)}
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

  defp generate_response(query, provider, context_source) do
    base_system = Identity.system_prompt(%{skill: :conversational})

    docs_instruction =
      if context_source in ["docs", "both"] do
        """

        IMPORTANT: When documentation is provided below, you MUST base your answer on that documentation.
        Quote specific function signatures, options, and examples from the docs.
        Do NOT answer from general knowledge when documentation is available — use the provided docs as your primary source.
        If the docs don't cover the question, say so explicitly.
        """
      else
        ""
      end

    system = base_system <> docs_instruction

    {memory_results, memory_context} =
      if context_source in ["memory", "both"] do
        results = Memory.search(query, limit: 5)

        context =
          case results do
            [] ->
              ""

            entries ->
              ctx =
                Enum.map_join(entries, "\n---\n", fn e ->
                  kind_label = String.upcase(e.kind)
                  "[#{kind_label}] #{String.slice(e.content, 0, 500)}"
                end)

              "\n\nRelevant knowledge from memory:\n#{ctx}"
          end

        {results, context}
      else
        {[], ""}
      end

    {knowledge_results, knowledge_context} =
      if context_source in ["docs", "both"] do
        results = Knowledge.search(query, limit: 5)

        context =
          case results do
            [] ->
              ""

            entries ->
              ctx =
                Enum.map_join(entries, "\n---\n", fn e ->
                  pkg = e.metadata["package"] || "unknown"
                  mod = e.metadata["module"] || ""
                  "[DOCS: #{pkg}/#{mod}] #{String.slice(e.content, 0, 1500)}"
                end)

              "\n\nRelevant documentation:\n#{ctx}"
          end

        {results, context}
      else
        {[], ""}
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

    prompt = "#{knowledge_context}#{memory_context}#{recent}\n\nUser: #{query}"

    opts =
      case provider do
        "auto" -> [tier: :light]
        name -> [provider: name]
      end

    case LLM.complete(prompt, opts ++ [system: system]) do
      {:ok, response} -> {response, length(memory_results), length(knowledge_results)}
      {:error, reason} -> {:error, reason}
    end
  end
end
