defmodule AlexClawWeb.Live.Elevation do
  @moduledoc """
  The elevation gate as the admin pages use it.

  Hiding a button is not a check — the browser can send the event regardless —
  so every control-plane handler makes its change through `gated/3` on the
  server, which hands it to `AlexClaw.ControlPlane.gated/4`: the elevation is
  checked there, and the change and its audit row are one transaction. This
  module turns the answer into what the page shows.

  With no second factor configured nothing can elevate, so every control-plane
  write is refused and the pages say how to make elevation possible. There is no
  state in which a write proceeds on the password alone.

  Pages take the session identifier at mount, subscribe to their own elevation
  topic, and re-render when it changes — so a code answered on Telegram unlocks
  the tab that asked, without a refresh.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3]

  alias AlexClaw.Auth.{AuditLog, CodeAttempts, CodeEntry, Elevation, Gate}
  alias AlexClaw.ControlPlane
  alias Phoenix.LiveView.Socket

  @refusal "Unlock editing first"
  @unrecorded "The change was not made: it could not be recorded in the audit log."
  # 2FA is set up in the admin UI with the password alone; no gateway needed.
  @unconfigured "Admin changes require 2FA. Set it up under Services → Two-factor authentication."

  @doc "What a page says when a change is refused because 2FA is not set up."
  @spec unconfigured_message() :: String.t()
  def unconfigured_message, do: @unconfigured

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
  Make one control-plane change from a page, through `AlexClaw.ControlPlane.gated/4`.

  `change` names the parts:

    * `:write` — the change itself, `(-> {:ok, result} | {:error, reason})`. It
      runs inside the transaction with its audit row, so it touches the database
      and nothing else.
    * `:after_commit` — `(result -> any)`, for everything that is not the
      database: caches, broadcasts, other nodes. Optional.
    * `:ok` — `(socket, result -> socket)`, what the page shows once committed.
    * `:error` — `(socket, reason -> socket)`, what it shows when the change was
      not made. Optional; the default says so in a flash.

  A refusal — no elevation, no second factor, or an audit row that could not be
  written — is answered here, the same way on every page.
  """
  @spec gated(Socket.t(), String.t(), keyword()) :: {:noreply, Socket.t()}
  def gated(socket, detail, change) do
    sid(socket)
    |> ControlPlane.gated(
      detail,
      Keyword.fetch!(change, :write),
      Keyword.get(change, :after_commit, fn _result -> :ok end)
    )
    |> replied(socket, Keyword.fetch!(change, :ok), Keyword.get(change, :error, &not_made/2))
  end

  defp replied({:ok, result}, socket, ok, _error), do: {:noreply, ok.(socket, result)}

  defp replied({:error, :not_elevated}, socket, _ok, _error),
    do: {:noreply, socket |> refresh() |> put_flash(:error, @refusal)}

  defp replied({:error, :no_second_factor}, socket, _ok, _error),
    do: {:noreply, socket |> refresh() |> put_flash(:error, @unconfigured)}

  defp replied({:error, :audit_failed}, socket, _ok, _error),
    do: {:noreply, put_flash(socket, :error, @unrecorded)}

  defp replied({:error, reason}, socket, _ok, error), do: {:noreply, error.(socket, reason)}

  defp not_made(socket, reason),
    do: put_flash(socket, :error, "Not saved: #{inspect(reason)}")

  @doc """
  Open the code field.

  The authenticator is the second factor, so the default way to give a code is
  to type it where you are. The gateway challenge stays available beside it for
  operators who would rather answer on another device.
  """
  @spec open_entry(Socket.t()) :: {:noreply, Socket.t()}
  def open_entry(socket), do: {:noreply, refresh(socket, true, nil)}

  @doc "Close the code field without submitting anything."
  @spec close_entry(Socket.t()) :: {:noreply, Socket.t()}
  def close_entry(socket), do: {:noreply, refresh(socket, false, nil)}

  @doc """
  Check a typed code and, if it holds, elevate this session.

  Wrong codes are counted against the session and the instance; the reply says
  which limit has been reached rather than repeating "invalid code" while the
  door is already bolted.
  """
  @spec submit_code(Socket.t(), String.t()) :: {:noreply, Socket.t()}
  def submit_code(socket, code) do
    sid = sid(socket)
    granted(CodeEntry.verify(sid, code, :web), sid, socket)
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
  def refresh(socket), do: refresh(socket, false, nil)

  @spec refresh(Socket.t(), boolean(), String.t() | nil) :: Socket.t()
  def refresh(socket, entry_open?, message) do
    assign(socket, :elevation, state(sid(socket), entry_open?, message))
  end

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

  The restore path refuses before any change is attempted, and a refusal
  nobody wrote down is a refusal nobody can review.
  """
  @spec audit_refusal(Socket.t(), :not_elevated | :no_second_factor, String.t()) :: :ok
  def audit_refusal(socket, reason, detail) do
    AuditLog.log_admin_refusal(fingerprint(socket), reason, detail)
  end

  # --- Internals ---

  defp granted(:ok, sid, socket) do
    {:ok, _expires_at} = Elevation.grant(sid)

    {:noreply,
     socket
     |> refresh(false, nil)
     |> put_flash(:info, "Editing unlocked for #{minutes()} minutes")}
  end

  defp granted({:error, reason}, _sid, socket) do
    {:noreply, refresh(socket, true, refusal_message(reason))}
  end

  defp refusal_message(:invalid_code), do: "That code is not valid. Try the next one."

  defp refusal_message(:locked_session),
    do: "Too many wrong codes. This session cannot try again for five minutes."

  defp refusal_message(:locked_instance),
    do: "Too many wrong codes across sessions. Code entry is locked for fifteen minutes."

  defp refusal_message(:not_configured),
    do: "No second factor is configured yet."

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

  # Every chat that could receive the prompt is locked after wrong codes; a
  # prompt it cannot answer is not sent, and the page says why.
  defp unlocking({:locked, minutes}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Code entry on your gateway is locked after too many wrong codes — try again in #{minutes} min"
     )}
  end

  # Enabled 2FA with nowhere to send the prompt is not a second factor, and
  # pretending otherwise would lock the operator out of their own settings.
  defp unlocking(:no_2fa, socket) do
    {:noreply,
     put_flash(socket, :error, "No gateway is configured to receive the code — cannot unlock")}
  end

  defp state(sid), do: state(sid, false, nil)

  defp state(sid, entry_open?, message) do
    %{
      configured?: Elevation.configured?(),
      elevated?: Elevation.elevated?(sid),
      expires_at: Elevation.expires_at(sid),
      entry_open?: entry_open?,
      lock: CodeAttempts.status(sid),
      message: message
    }
  end

  defp subscribe(true, sid) when is_binary(sid), do: Elevation.subscribe(sid)
  defp subscribe(_connected?, _sid), do: :ok

  defp sid(%{assigns: %{elevation_sid: sid}}), do: sid
  defp sid(_socket), do: nil

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
