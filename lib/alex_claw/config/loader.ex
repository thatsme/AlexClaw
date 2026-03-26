defmodule AlexClaw.Config.Loader do
  @moduledoc """
  Initializes the Config ETS table on application start.
  """
  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # 0. Ensure skills directory exists
    skills_dir = Application.get_env(:alex_claw, :skills_dir, "/app/skills")
    File.mkdir_p!(skills_dir)

    # 1. Create ETS table and load raw DB values
    AlexClaw.Config.init()
    # 2. Seed defaults (marks sensitive keys, encrypts new values)
    AlexClaw.Config.Seeder.seed()
    # 3. Encrypt any remaining plaintext sensitive values
    AlexClaw.Config.EncryptExisting.run()
    # 4. Reload ETS with decrypted values
    AlexClaw.Config.init()
    # 5. Seed default LLM providers (reads API keys from Config)
    unless Application.get_env(:alex_claw, :skip_provider_seed, false) do
      AlexClaw.LLM.ProviderSeeder.seed()
    end
    # 6. Load self-awareness docs into knowledge base (background, non-blocking)
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      AlexClaw.Knowledge.SelfAwareness.load()
    end)
    # 7. Subscribe to config changes for cross-node ETS sync
    AlexClaw.Config.subscribe()
    {:ok, %{}}
  catch
    :error, %Postgrex.Error{} = e ->
      Logger.warning("Config seeder skipped (DB not ready): #{Exception.message(e)}")
      {:ok, %{}}
  end

  @impl true
  def handle_info({:config_changed, _key, _value}, state) do
    # Reload ETS from DB to pick up changes from other nodes.
    # Only reload if in a cluster — local changes are already in ETS.
    if Node.list() != [] do
      try do
        AlexClaw.Config.init()
      rescue
        _ -> :ok
      end
    end

    {:noreply, state}
  end
end
