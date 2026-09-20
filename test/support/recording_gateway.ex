defmodule AlexClaw.RecordingGateway do
  @moduledoc """
  A gateway that keeps what it was asked to send.

  Some claims are about the wire rather than about a function: "a recovery code
  is never sent over a gateway" cannot be checked by reading the function that
  does not send it. This implements the gateway contract, records every
  outbound message, and lets a test read them back.

  Install it for one test with `AlexClaw.RecordingGateway.install/0`, which
  points the router here and restores the real list afterwards.
  """
  @behaviour AlexClaw.Gateway.Behaviour

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc """
  Route outbound messages here for the duration of one test.

  Restores the previous gateway list on exit, so a test that installs it cannot
  silence the next one.
  """
  @spec install() :: :ok
  def install do
    ensure_started()
    clear()
    previous = Application.get_env(:alex_claw, :gateways)
    Application.put_env(:alex_claw, :gateways, [__MODULE__])

    ExUnit.Callbacks.on_exit(fn -> restore(previous) end)
  end

  @doc "Every message sent since the last clear, newest last."
  @spec sent() :: [String.t()]
  def sent do
    ensure_started()
    Agent.get(__MODULE__, &Enum.reverse/1)
  end

  @doc "Forget what was sent."
  @spec clear() :: :ok
  def clear do
    ensure_started()
    Agent.update(__MODULE__, fn _messages -> [] end)
  end

  # --- Gateway contract ---

  @impl true
  def send_message(text, _opts \\ []), do: record(text)

  @impl true
  def send_html(text, _opts \\ []), do: record(text)

  @impl true
  def send_photo(_chat_id, _photo_data, caption), do: record(caption)

  @impl true
  def name, do: :recording

  @impl true
  def configured?, do: true

  # --- Internals ---

  defp record(text) do
    ensure_started()
    Agent.update(__MODULE__, &[to_string(text) | &1])
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _pid -> :ok
    end

    :ok
  end

  defp restore(nil), do: Application.delete_env(:alex_claw, :gateways)
  defp restore(previous), do: Application.put_env(:alex_claw, :gateways, previous)
end
