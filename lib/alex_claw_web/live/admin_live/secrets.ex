defmodule AlexClawWeb.AdminLive.Secrets do
  @moduledoc """
  The Secrets page: the catalogue of secrets AlexClaw may use — names, kinds,
  bindings, and when each value was last set.

  It never renders a value, or any part of one. Setting a value is its own
  action, through a password field that is empty every time it is shown.
  Every write — defining, setting a value, deleting — goes through
  `AlexClawWeb.Live.Elevation.gated/3`: second factor and audit.
  """
  use Phoenix.LiveView

  alias AlexClaw.Secrets
  alias AlexClaw.Secrets.Secret
  alias AlexClawWeb.Live.Elevation

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> Elevation.assign_elevation(session)
     |> assign(page_title: "Secrets", kinds: Secret.kinds(), show_form: false, value_for: nil)
     |> assign_secrets()}
  end

  @impl true
  def handle_info({:elevation, _state, _detail} = message, socket) do
    {:noreply, Elevation.handle_broadcast(socket, message)}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle_form", _params, socket),
    do: {:noreply, assign(socket, show_form: !socket.assigns.show_form)}

  def handle_event("save_secret", %{"secret" => params}, socket) do
    attrs = secret_attrs(params)

    Elevation.gated(socket, "secret defined: #{attrs.name}",
      write: fn -> Secrets.define(attrs) end,
      ok: fn socket, secret ->
        socket
        |> put_flash(:info, "Secret #{secret.name} defined. It has no value yet.")
        |> assign(show_form: false)
        |> assign_secrets()
      end,
      error: &not_saved/2
    )
  end

  def handle_event("edit_value", %{"name" => name}, socket),
    do: {:noreply, assign(socket, value_for: name)}

  def handle_event("cancel_value", _params, socket),
    do: {:noreply, assign(socket, value_for: nil)}

  # The value is passed to OpenBao and dropped: it is never assigned, so the
  # page cannot render it back.
  def handle_event("set_value", %{"name" => name, "value" => value}, socket) do
    Elevation.gated(socket, "secret value set: #{name}",
      write: fn -> done(Secrets.put_value(name, value), name) end,
      ok: fn socket, name ->
        socket
        |> put_flash(:info, "Value of #{name} set.")
        |> assign(value_for: nil)
        |> assign_secrets()
      end,
      error: &not_saved/2
    )
  end

  def handle_event("delete_secret", %{"name" => name}, socket) do
    Elevation.gated(socket, "secret deleted: #{name}",
      write: fn -> done(Secrets.delete(name), name) end,
      ok: fn socket, name ->
        socket
        |> put_flash(:info, "Secret #{name} deleted, with its value.")
        |> assign_secrets()
      end,
      error: &not_saved/2
    )
  end

  def handle_event("unlock_editing", _params, socket), do: Elevation.open_entry(socket)

  def handle_event("submit_code", %{"code" => code}, socket),
    do: Elevation.submit_code(socket, code)

  def handle_event("cancel_code", _params, socket), do: Elevation.close_entry(socket)
  def handle_event("request_gateway_code", _params, socket), do: Elevation.unlock(socket)

  defp assign_secrets(socket), do: assign(socket, secrets: Secrets.list())

  # The binding is typed as a list separated by commas or whitespace.
  defp secret_attrs(params) do
    %{
      name: String.trim(params["name"] || ""),
      description: blank_to_nil(params["description"]),
      kind: params["kind"],
      binding: String.split(params["binding"] || "", [",", " ", "\n"], trim: true)
    }
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp done(:ok, name), do: {:ok, name}
  defp done({:error, reason}, _name), do: {:error, reason}

  defp not_saved(socket, %Ecto.Changeset{} = changeset),
    do: put_flash(socket, :error, "Not saved: #{errors(changeset)}")

  defp not_saved(socket, reason), do: put_flash(socket, :error, "Not saved: #{describe(reason)}")

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp describe(:vault_unavailable), do: "OpenBao is unavailable"
  defp describe(:unknown_secret), do: "no such secret"
  defp describe(:empty_value), do: "the value is empty"
  defp describe(reason), do: inspect(reason)
end
