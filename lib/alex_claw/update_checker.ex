defmodule AlexClaw.UpdateChecker do
  @moduledoc """
  Periodically checks GitHub for newer releases.
  Caches the result in ETS to avoid hitting the API on every dashboard load.
  """
  use GenServer
  require Logger

  @repo "thatsme/AlexClaw"
  @check_interval :timer.hours(6)
  @table :alexclaw_update_check

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns the latest release info or nil if not yet checked."
  @spec status() :: %{latest: String.t(), current: String.t(), update_available: boolean()} | nil
  def status do
    case :ets.lookup(@table, :latest) do
      [{:latest, info}] -> info
      [] -> nil
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set])
    Process.send_after(self(), :check, :timer.seconds(5))
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    check_for_updates()
    Process.send_after(self(), :check, @check_interval)
    {:noreply, state}
  end

  defp check_for_updates do
    current = Application.spec(:alex_claw, :vsn) |> to_string() |> strip_build()

    headers = [{"accept", "application/vnd.github+json"}]

    case Req.get("https://api.github.com/repos/#{@repo}/releases/latest", headers: headers) do
      {:ok, %{status: 200, body: %{"tag_name" => tag}}} ->
        latest = String.trim_leading(tag, "v")

        info = %{
          latest: latest,
          current: current,
          update_available: Version.compare(current, latest) == :lt
        }

        :ets.insert(@table, {:latest, info})
        if info.update_available, do: Logger.info("Update available: v#{latest} (running v#{current})")

      {:ok, %{status: status}} ->
        Logger.warning("Update check: GitHub API returned #{status}")

      {:error, reason} ->
        Logger.warning("Update check failed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("Update check error: #{Exception.message(e)}")
  end

  defp strip_build(version) do
    version |> String.split("+") |> hd()
  end
end
