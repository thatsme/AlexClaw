defmodule AlexClaw.Config.EncryptExisting do
  @moduledoc """
  One-time migration task that encrypts existing plaintext sensitive settings.
  Idempotent — skips values that are already encrypted or empty.
  Called from Loader on every boot (no-op after first run).
  """
  require Logger
  import Ecto.Query
  alias AlexClaw.Repo
  alias AlexClaw.Config.{Setting, Crypto}

  @spec run() :: :ok
  def run do
    Setting
    |> where([s], s.sensitive == true)
    |> Repo.all()
    |> Enum.reject(fn s -> s.value == "" or is_nil(s.value) or Crypto.encrypted?(s.value) end)
    |> Enum.each(fn setting ->
      case Crypto.encrypt(setting.value) do
        {:ok, encrypted} ->
          setting
          |> Ecto.Changeset.change(%{value: encrypted})
          |> Repo.update!()

          Logger.info("Encrypted setting: #{setting.key}")

        {:error, reason} ->
          Logger.error("Failed to encrypt setting #{setting.key}: #{inspect(reason)}")
      end
    end)

    :ok
  catch
    :error, %Postgrex.Error{} = e ->
      Logger.warning("EncryptExisting skipped (DB not ready): #{Exception.message(e)}")
      :ok
  end
end
