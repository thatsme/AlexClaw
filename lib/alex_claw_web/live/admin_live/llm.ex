defmodule AlexClawWeb.AdminLive.LLM do
  @moduledoc "LiveView page for configuring LLM providers (all stored in DB)."

  use Phoenix.LiveView

  alias AlexClaw.LLM

  @provider_types ~w(openai_compatible ollama gemini anthropic custom)
  @tiers ~w(light medium heavy local)

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(10_000, :refresh_usage)

    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh_usage, socket) do
    {:noreply, assign(socket, providers: build_providers())}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_form", _, socket) do
    {:noreply, assign(socket, show_form: !socket.assigns.show_form, editing: nil, form_type: "openai_compatible")}
  end

  @impl true
  def handle_event("type_changed", %{"type" => type}, socket) do
    {:noreply, assign(socket, form_type: type)}
  end

  @impl true
  def handle_event("edit_provider", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, provider_id} ->
        case LLM.get_provider(provider_id) do
          {:ok, provider} ->
            {:noreply, assign(socket, editing: provider, show_form: true, form_type: provider.type)}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Provider not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_provider", params, socket) do
    attrs = %{
      name: params["name"],
      type: params["type"],
      tier: params["tier"],
      host: blank_to_nil(params["host"]),
      model: params["model"],
      api_key: blank_to_nil(params["api_key"]),
      daily_limit: parse_int(params["daily_limit"]),
      priority: parse_int(params["priority"]) || 100,
      enabled: params["enabled"] == "true",
      options: parse_options(params)
    }

    result =
      case socket.assigns.editing do
        nil -> LLM.create_provider(attrs)
        provider -> LLM.update_provider(provider, drop_blank_api_key(attrs, provider))
      end

    case result do
      {:ok, _} ->
        action = if socket.assigns.editing, do: "updated", else: "added"

        {:noreply,
         socket
         |> put_flash(:info, "Provider #{action}")
         |> assign(show_form: false, editing: nil)
         |> assign_data()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("delete_provider", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, provider_id} ->
        case LLM.get_provider(provider_id) do
          {:ok, provider} ->
            {:ok, _} = LLM.delete_provider(provider)

            {:noreply,
             socket
             |> put_flash(:info, "Provider deleted")
             |> assign_data()}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Provider not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_form", _, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil)}
  end

  @impl true
  def handle_event("test_provider", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, provider_id} ->
        case LLM.get_provider(provider_id) do
          {:ok, provider} ->
            result =
              case LLM.complete("Reply with only: OK", provider: provider.name) do
                {:ok, text} -> "OK: #{String.slice(text, 0, 50)}"
                {:error, reason} -> "Error: #{inspect(reason)}"
              end

            {:noreply, put_flash(socket, :info, "#{provider.name}: #{result}")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Provider not found")}
        end

      :error ->
        {:noreply, socket}
    end
  end

  defp assign_data(socket) do
    assign(socket,
      page_title: "LLM Providers",
      providers: build_providers(),
      editing: nil,
      show_form: false,
      form_type: "openai_compatible",
      provider_types: @provider_types,
      tiers: @tiers
    )
  end

  defp build_providers do
    Enum.map(LLM.list_providers(), fn p ->
      Map.put(p, :usage_today, LLM.usage_today(p.id))
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(val), do: val

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp drop_blank_api_key(%{api_key: nil} = attrs, _provider), do: Map.delete(attrs, :api_key)
  defp drop_blank_api_key(attrs, _provider), do: attrs

  @option_fields [
    {"num_ctx", :integer},
    {"num_predict", :integer},
    {"temperature", :float},
    {"top_p", :float},
    {"top_k", :integer},
    {"repeat_penalty", :float},
    {"num_thread", :integer},
    {"num_gpu", :integer},
    {"thinking", :boolean}
  ]

  defp parse_options(params) do
    Enum.reduce(@option_fields, %{}, fn {key, type}, acc ->
      case parse_option_value(params["opt_" <> key], type) do
        nil -> acc
        val -> Map.put(acc, key, val)
      end
    end)
  end

  defp parse_option_value(nil, _type), do: nil
  defp parse_option_value("", _type), do: nil

  defp parse_option_value(val, :integer) do
    case Integer.parse(val) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_option_value(val, :float) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_option_value("true", :boolean), do: true
  defp parse_option_value("false", :boolean), do: false
  defp parse_option_value(_, :boolean), do: nil

  defp get_option(nil, _key), do: ""
  defp get_option(provider, key) do
    case Map.get(provider.options || %{}, key) do
      nil -> ""
      val -> val
    end
  end

  defp mask_value(val) when is_binary(val) and byte_size(val) > 8 do
    String.slice(val, 0, 4) <> "********" <> String.slice(val, -4, 4)
  end

  defp mask_value(_), do: ""

  defp format_limit(nil), do: "unlimited"
  defp format_limit(n), do: "#{n}/day"

  defp show_option?(type, opt) do
    case type do
      "ollama" -> opt in ~w(num_ctx num_predict temperature top_p top_k repeat_penalty num_thread num_gpu)
      "openai_compatible" -> opt in ~w(temperature top_p num_predict thinking)
      "custom" -> opt in ~w(temperature top_p num_predict thinking)
      "gemini" -> opt in ~w(temperature top_p num_predict)
      "anthropic" -> opt in ~w(temperature top_p num_predict)
      _ -> false
    end
  end

  defp tier_badge_class(tier) do
    base = "text-xs px-2 py-1 rounded font-mono"

    color =
      case tier do
        "light" -> "bg-green-900 text-green-300"
        "medium" -> "bg-yellow-900 text-yellow-300"
        "heavy" -> "bg-red-900 text-red-300"
        "local" -> "bg-purple-900 text-purple-300"
        _ -> "bg-gray-800 text-gray-400"
      end

    "#{base} #{color}"
  end
end
