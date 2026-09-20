defmodule AlexClawWeb.Live.Elevation do
  @moduledoc """
  The elevation gate as the admin pages use it.

  Hiding a button is not a check — the browser can send the event regardless —
  so every control-plane handler runs its write inside `gate/3` on the server.
  It answers three questions in order: is elevation enforced on this instance,
  does this session hold one, and what should the audit row say.

  With no second factor configured nothing can elevate, so every control-plane
  write is refused and the pages say how to make elevation possible. There is no
  state in which a write proceeds on the password alone.

  Pages take the session identifier at mount, subscribe to their own elevation
  topic, and re-render when it changes — so a code answered on Telegram unlocks
  the tab that asked, without a refresh.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]

  alias AlexClaw.Auth.{AuditLog, Elevation, Gate}
  alias Phoenix.LiveView.Socket

  @refusal "Unlock editing first"
  @unconfigured "Admin changes require 2FA. Configure a gateway via environment " <>
                  "variables and run /setup 2fa."

  @doc """
  Assign what a gated page needs, and follow this session's elevation.

  Call from `mount/3` with the session map.
  """
  @spec assign_elevation(Socket.t(), map()) :: Socket.t()
  def assign_elevation(socket, session) do
    sid = session["elevation_sid"]
    subscribe(connected?(socket), sid)

    socket
    |> assign(:elevation_sid, sid)
    |> assign(:elevation, state(sid))
  end

  @doc """
  Perform a control-plane write, or refuse it.

  `detail` is what the audit row will say — the key and the old and new values
  for a setting, the name and id for a record. Mask secrets before passing them
  in; `describe_setting/3` does that for configuration.
  """
  @spec gate(Socket.t(), String.t(), (-> {:noreply, Socket.t()})) :: {:noreply, Socket.t()}
  def gate(socket, detail, write) do
    decide(elevated?(socket), socket, detail, write)
  end

  @doc "Raise a 2FA challenge that will unlock this session when answered."
  @spec unlock(Socket.t()) :: {:noreply, Socket.t()}
  def unlock(socket), do: request_unlock(sid(socket), socket)

  @doc "Apply an elevation broadcast to a page that is following one."
  @spec handle_broadcast(Socket.t(), tuple()) :: Socket.t()
  def handle_broadcast(socket, {:elevation, :granted, _expires_at}) do
    socket
    |> refresh()
    |> put_flash(:info, "Editing unlocked for #{minutes()} minutes")
  end

  def handle_broadcast(socket, {:elevation, :ended, reason}) do
    socket
    |> refresh()
    |> put_flash(:info, ended(reason))
  end

  @doc "Recompute the elevation assign — after a grant, a refusal, or an expiry."
  @spec refresh(Socket.t()) :: Socket.t()
  def refresh(socket), do: assign(socket, :elevation, state(sid(socket)))

  @doc """
  Describe a configuration change for the audit log, masking sensitive values.

  A secret's old and new values are both replaced: the record is that the key
  changed and who changed it, never what it changed to.
  """
  @spec describe_setting(String.t(), term(), term()) :: String.t()
  def describe_setting(key, old, new) do
    "#{key}: #{shown(key, old)} → #{shown(key, new)}"
  end

  @doc """
  Record a refusal for a write that is gated per action rather than by window.

  The restore path refuses before it reaches `gate/3`, and a refusal nobody
  wrote down is a refusal nobody can review.
  """
  @spec audit_refusal(Socket.t(), :not_elevated | :no_second_factor, String.t()) :: :ok
  def audit_refusal(socket, reason, detail) do
    AuditLog.log_admin_refusal(fingerprint(socket), reason, detail)
  end

  # --- Internals ---

  defp decide(true, socket, detail, write) do
    AuditLog.log_admin_write(fingerprint(socket), detail)
    write.()
  end

  # Two ways to hold no elevation, and they need different answers: one session
  # can unlock, the other is on an instance where nothing can.
  defp decide(false, socket, detail, _write) do
    refuse(Elevation.configured?(), socket, detail)
  end

  defp refuse(true, socket, detail) do
    AuditLog.log_admin_refusal(fingerprint(socket), :not_elevated, detail)

    {:noreply,
     socket
     |> refresh()
     |> put_flash(:error, @refusal)}
  end

  defp refuse(false, socket, detail) do
    AuditLog.log_admin_refusal(fingerprint(socket), :no_second_factor, detail)

    {:noreply,
     socket
     |> refresh()
     |> put_flash(:error, @unconfigured)}
  end

  defp request_unlock(sid, socket) when is_binary(sid) do
    %{type: :elevate, sid: sid}
    |> Gate.request("Unlock admin editing for #{minutes()} minutes")
    |> unlocking(socket)
  end

  defp request_unlock(_sid, socket) do
    {:noreply, put_flash(socket, :error, "This session has no identifier — sign in again")}
  end

  defp unlocking(:challenged, socket) do
    {:noreply, put_flash(socket, :info, "2FA code requested — check Telegram/Discord")}
  end

  # Enabled 2FA with nowhere to send the prompt is not a second factor, and
  # pretending otherwise would lock the operator out of their own settings.
  defp unlocking(:no_2fa, socket) do
    {:noreply,
     put_flash(socket, :error, "No gateway is configured to receive the code — cannot unlock")}
  end

  defp state(sid) do
    %{
      configured?: Elevation.configured?(),
      elevated?: Elevation.elevated?(sid),
      expires_at: Elevation.expires_at(sid)
    }
  end

  defp subscribe(true, sid) when is_binary(sid), do: Elevation.subscribe(sid)
  defp subscribe(_connected?, _sid), do: :ok

  defp sid(%{assigns: %{elevation_sid: sid}}), do: sid
  defp sid(_socket), do: nil

  defp elevated?(socket), do: Elevation.elevated?(sid(socket))

  defp fingerprint(socket), do: print(sid(socket))

  defp print(sid) when is_binary(sid), do: Elevation.fingerprint(sid)
  defp print(_sid), do: "unidentified"

  defp shown(key, value) do
    mask(AlexClaw.Config.sensitive?(key), value)
  end

  defp mask(true, _value), do: "***"
  defp mask(false, nil), do: "(unset)"
  defp mask(false, value), do: inspect(to_string(value))

  defp ended(:expired), do: "Editing locked — the fifteen minutes are up"
  defp ended(:revoked), do: "Editing locked"

  defp minutes, do: div(Elevation.window_seconds(), 60)
end
