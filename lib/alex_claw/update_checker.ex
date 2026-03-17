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

    token = AlexClaw.Config.get("github.token") || ""

    headers =
      if token != "",
        do: [{"authorization", "Bearer #{token}"}, {"accept", "application/vnd.github+json"}],
        else: [{"accept", "application/vnd.github+json"}]

    case Req.get("https://api.github.com/repos/#{@repo}/releases/latest", headers: headers) do
      {:ok, %{status: 200, body: %{"tag_name" => tag}}} ->
        latest = tag |> String.trim_leading("v")

        info = %{
          latest: latest,
          current: current,
          update_available: Version.compare(current, latest) == :lt
        }

        :ets.insert(@table, {:latest, info})
        if info.update_available, do: Logger.info("Update available: v#{latest} (running v#{current})")

      {:ok, %{status: status}} ->
        Logger.debug("Update check: GitHub API returned #{status}")

      {:error, reason} ->
        Logger.debug("Update check failed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.debug("Update check error: #{Exception.message(e)}")
  end

  defp strip_build(version) do
    version |> String.split("+") |> hd()
  end
end
