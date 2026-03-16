defmodule AlexClaw.Config.Loader do
  @moduledoc """
  Initializes the Config ETS table on application start.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    AlexClaw.Config.init()
    AlexClaw.Config.Seeder.seed()
    {:ok, %{}}
  catch
    :error, %Postgrex.Error{} = e ->
      Logger.warning("Config seeder skipped (DB not ready): #{Exception.message(e)}")
      {:ok, %{}}
  end
end
