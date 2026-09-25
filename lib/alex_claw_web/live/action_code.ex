defmodule AlexClawWeb.Live.ActionCode do
  @moduledoc """
  Confirming one action with a code, from the page that asked for it.

  These are the actions an elevation deliberately does not satisfy — loading
  a skill, approving generated code, running a workflow marked `requires_2fa`,
  restoring the database. Each needs a code of its own (`:code` in
  `AlexClaw.ControlPlane.catalogue/0`).

  The action and its params wait in the challenge store, keyed by session;
  the typed code is handed to `AlexClaw.ControlPlane.perform/3`, which checks
  it and performs the action. A protected workflow run is also sent to the
  gateway, since a chat may approve that one (and nothing else): whichever is
  answered first performs it and withdraws the other.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias AlexClaw.Auth.{Challenge, Gate, Principal}
  alias AlexClaw.ControlPlane
  alias AlexClaw.ControlPlane.Context
  alias Phoenix.LiveView.Socket

  @code_refusals [:invalid_code, :locked_session, :locked_instance, :not_configured]

  @doc """
  Ask for a code for the catalogued `action` with `params`. The page shows a
  field; for a protected workflow run, a gateway also shows the prompt.
  `description` is what the operator is told they are approving.
  """
  @spec request(Socket.t(), atom(), map(), String.t()) :: {:noreply, Socket.t()}
  def request(socket, action, params, description) do
    Challenge.create_for_session(sid(socket), %{
      action: action,
      params: params,
      requested_by: Principal.requested_by()
    })

    prompt_gateways(action, params, description)

    {:noreply,
     assign(socket, :action_code, %{open?: true, description: description, message: nil})}
  end

  defp prompt_gateways(:run_protected_workflow, %{workflow_id: id}, description),
    do: Gate.request(%{type: :run_workflow, workflow_id: id}, description)

  defp prompt_gateways(_action, _params, _description), do: :ok

  @doc "Check a typed code and, if it holds, perform the waiting action."
  @spec submit(Socket.t(), String.t()) :: {:noreply, Socket.t()}
  def submit(socket, code) do
    sid = sid(socket)

    sid
    |> Challenge.pending_for_session()
    |> perform(code, sid, socket)
  end

  @doc "Abandon the waiting action, on the page and on the gateway."
  @spec cancel(Socket.t()) :: {:noreply, Socket.t()}
  def cancel(socket) do
    Challenge.drop_for_session(sid(socket))

    {:noreply, closed(socket)}
  end

  @doc "The initial assign, for a page that has asked for nothing yet."
  @spec assign_action_code(Socket.t()) :: Socket.t()
  def assign_action_code(socket) do
    assign(socket, :action_code, %{open?: false, description: nil, message: nil})
  end

  # --- Internals ---

  defp perform({:ok, %{action: action, params: params}}, code, sid, socket) do
    action
    |> ControlPlane.perform(params, Context.admin_ui(sid, code))
    |> performed(sid, socket)
  end

  # Two minutes is not long, and an approval that expired is not an approval.
  defp perform(_expired, _code, _sid, socket),
    do: {:noreply, message(socket, "That request has expired. Start it again.")}

  # A wrong code leaves the request waiting for the next one.
  defp performed({:error, reason}, _sid, socket) when reason in @code_refusals,
    do: {:noreply, message(socket, refusal(reason))}

  defp performed(result, sid, socket) do
    Challenge.drop_for_session(sid)
    withdraw_gateway_challenges()
    {:noreply, socket |> closed() |> confirmed(result)}
  end

  defp confirmed(socket, {:error, reason}),
    do: put_flash(socket, :error, "Not done: #{inspect(reason)}")

  defp confirmed(socket, _done), do: put_flash(socket, :info, "Confirmed.")

  # The same run may also be waiting on every configured gateway. Leaving it
  # there would let a second code perform it twice.
  defp withdraw_gateway_challenges do
    for chat_id <- Gate.notify_targets(), do: Challenge.drop(chat_id)
    :ok
  end

  defp closed(socket) do
    assign(socket, :action_code, %{open?: false, description: nil, message: nil})
  end

  defp message(socket, text) do
    assign(socket, :action_code, %{socket.assigns.action_code | message: text})
  end

  defp refusal(:invalid_code), do: "That code is not valid. Try the next one."

  defp refusal(:locked_session),
    do: "Too many wrong codes. This session cannot try again for five minutes."

  defp refusal(:locked_instance),
    do: "Too many wrong codes across sessions. Code entry is locked for fifteen minutes."

  defp refusal(:not_configured), do: "No second factor is configured yet."

  defp sid(%{assigns: %{elevation_sid: sid}}), do: sid
  defp sid(_socket), do: nil
end
