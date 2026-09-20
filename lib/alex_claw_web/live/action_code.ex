defmodule AlexClawWeb.Live.ActionCode do
  @moduledoc """
  Confirming one action with a code, from the page that asked for it.

  These are the gates an elevation deliberately does not satisfy — loading a
  skill, approving generated code, running a workflow marked `requires_2fa`,
  restoring the database. Each needs a code of its own, and until now the only
  place to type it was a gateway.

  The action waits in the same supervised store as a gateway challenge, keyed
  by session instead of by chat, and is performed by the same
  `execute_2fa_action/2`. One execution path; two ways to supply the code.

  Both ways are live at once: raising a web challenge also sends the gateway
  prompt, and whichever is answered first performs the action and withdraws the
  other. Otherwise an operator who typed the code would leave a challenge
  standing that a later code could answer a second time.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias AlexClaw.Auth.{CodeEntry, Gate, TOTP}
  alias AlexClaw.Dispatcher.AuthCommands
  alias AlexClaw.Message
  alias Phoenix.LiveView.Socket

  @doc """
  Ask for a code for `action`, on the page and on any gateway.

  The page shows a field; a gateway, if one is configured, shows the prompt it
  always did. `description` is what the operator is told they are approving.
  """
  @spec request(Socket.t(), map(), String.t()) :: {:noreply, Socket.t()}
  def request(socket, action, description) do
    sid = sid(socket)
    TOTP.create_web_challenge(sid, action)
    Gate.request(action, description)

    {:noreply,
     assign(socket, :action_code, %{open?: true, description: description, message: nil})}
  end

  @doc "Check a typed code and, if it holds, perform the waiting action."
  @spec submit(Socket.t(), String.t()) :: {:noreply, Socket.t()}
  def submit(socket, code) do
    sid = sid(socket)
    perform(CodeEntry.verify(sid, code, :web), sid, socket)
  end

  @doc "Abandon the waiting action, on the page and on the gateway."
  @spec cancel(Socket.t()) :: {:noreply, Socket.t()}
  def cancel(socket) do
    TOTP.drop_web_challenge(sid(socket))

    {:noreply, closed(socket)}
  end

  @doc "The initial assign, for a page that has asked for nothing yet."
  @spec assign_action_code(Socket.t()) :: Socket.t()
  def assign_action_code(socket) do
    assign(socket, :action_code, %{open?: false, description: nil, message: nil})
  end

  # --- Internals ---

  defp perform(:ok, sid, socket) do
    sid
    |> TOTP.take_web_action()
    |> run(sid, socket)
  end

  defp perform({:error, reason}, _sid, socket) do
    {:noreply, message(socket, refusal(reason))}
  end

  defp run({:ok, action}, sid, socket) do
    withdraw_gateway_challenges()
    AuthCommands.execute_2fa_action(action, confirmation_context(sid))

    {:noreply,
     socket
     |> closed()
     |> put_flash(:info, "Confirmed.")}
  end

  # Two minutes is not long, and an approval that expired is not an approval.
  defp run(:error, _sid, socket) do
    {:noreply, message(socket, "That request has expired. Start it again.")}
  end

  # The same action was also waiting on every configured gateway. Leaving it
  # there would let a second code perform it twice.
  defp withdraw_gateway_challenges do
    for chat_id <- Gate.notify_targets(), do: TOTP.drop_challenge(chat_id)
    :ok
  end

  # execute_2fa_action/2 reports back over a gateway for actions that came from
  # one. A web confirmation has no chat to answer, and the page says so itself.
  defp confirmation_context(sid) do
    %Message{
      chat_id: "web:" <> String.slice(sid, 0, 8),
      timestamp: DateTime.utc_now(),
      raw: %{},
      gateway: nil
    }
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
