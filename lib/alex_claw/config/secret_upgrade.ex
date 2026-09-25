defmodule AlexClaw.Config.SecretUpgrade do
  @moduledoc """
  At boot, before the gateways start: moves every declared-secret setting that
  still holds a value in the settings table into OpenBao, so no credential
  configured before 0.4.0 is lost or has to be entered again.

  For each such setting, in this order:

  1. the value is read from the settings table, decrypted under the running
     `SECRET_KEY_BASE`;
  2. it is stored in OpenBao through `AlexClaw.Config.SecretSettings.store/2`
     (catalogued, bound as declared, audited);
  3. it is READ BACK from OpenBao and compared with what was read in step 1;
  4. only then is the value emptied in the settings table.

  Any failure — OpenBao unreachable, a write refused, a value that does not
  decrypt, a read-back that differs — leaves the database copy exactly as it
  was, is logged by the setting's name (never its value), and the move is tried
  again at the next start. A setting already moved, or never set, is left
  alone, so running this at every boot changes nothing once everything is in
  OpenBao.
  """
  require Logger

  alias AlexClaw.Config.{Crypto, SecretSettings, Setting}
  alias AlexClaw.{Repo, Secrets, Vault}

  @type result :: %{moved: [String.t()], failed: [{String.t(), term()}]}

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}

  @doc false
  @spec start_link() :: :ignore
  def start_link do
    run() |> report()
    :ignore
  end

  @doc "Move every declared-secret setting that still holds a value. Returns what moved and what did not."
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    SecretSettings.keys()
    |> Enum.map(&{&1, pending(Repo.get_by(Setting, key: &1))})
    |> Enum.reject(fn {_key, pending} -> pending == :nothing end)
    |> moved_all(Keyword.get(opts, :vault, Vault))
  end

  defp pending(nil), do: :nothing
  defp pending(%Setting{value: value}) when value in [nil, ""], do: :nothing
  defp pending(%Setting{} = setting), do: {:move, setting}

  # Nothing to move: OpenBao is not even asked, so an instance without it boots
  # as before once everything has moved.
  defp moved_all([], _vault), do: %{moved: [], failed: []}

  defp moved_all(pending, vault), do: pending |> by_status(Vault.status(server: vault)) |> tally()

  defp by_status(pending, :ok), do: Enum.map(pending, fn {key, {:move, s}} -> {key, move(s)} end)

  defp by_status(pending, {:error, reason}),
    do: Enum.map(pending, fn {key, _move} -> {key, {:error, {:vault, reason}}} end)

  defp move(%Setting{key: key, value: stored} = setting) do
    with {:ok, value} <- plaintext(Crypto.decrypt(stored)),
         :ok <- SecretSettings.store(key, value),
         :ok <- read_back(SecretSettings.secret_name(key), value),
         {:ok, _setting} <- setting |> Ecto.Changeset.change(value: "") |> Repo.update() do
      :ok
    end
  end

  defp plaintext({:ok, value}) when is_binary(value) and value != "", do: {:ok, value}
  defp plaintext({:ok, _empty}), do: {:error, :empty}
  defp plaintext({:error, _reason}), do: {:error, :does_not_decrypt}

  defp read_back(name, value) do
    case Secrets.value_matches?(name, value) do
      true -> :ok
      false -> {:error, :read_back_differs}
      {:error, reason} -> {:error, {:read_back, reason}}
    end
  end

  defp tally(results) do
    %{
      moved: for({key, :ok} <- results, do: key),
      failed: for({key, {:error, reason}} <- results, do: {key, reason})
    }
  end

  defp report(%{moved: [], failed: []}), do: :ok

  defp report(%{moved: moved, failed: failed}) do
    if moved != [],
      do:
        Logger.info(
          "Moved to OpenBao: #{Enum.join(moved, ", ")} (the settings table keeps no value)"
        )

    Enum.each(failed, fn {key, reason} ->
      Logger.error(
        "NOT moved to OpenBao: #{key} (#{inspect(reason)}). Its database copy is untouched; " <>
          "the move is tried again at the next start."
      )
    end)
  end
end
