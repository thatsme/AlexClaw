defmodule AlexClaw.Config.Loader do
  @moduledoc """
  Initializes the Config ETS table on application start.
  """
  use GenServer
  require Logger
  alias AlexClaw.Auth.SecondFactor
  alias AlexClaw.Config.EncryptExisting
  alias AlexClaw.Config.Seeder
  alias AlexClaw.Gateway
  alias AlexClaw.Gateway.Router
  alias AlexClaw.Knowledge.SelfAwareness
  alias AlexClaw.LLM.ProviderSeeder
  alias AlexClaw.RAG.QueryRewriter
  alias AlexClaw.Skills.Shell

  # Long enough for the gateways to have started, since the report goes out over
  # one of them.
  @audit_delay_ms :timer.seconds(15)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # 0. Ensure skills directory exists
    skills_dir = Application.get_env(:alex_claw, :skills_dir, "/app/skills")
    File.mkdir_p!(skills_dir)

    # 1. Create ETS tables and load raw DB values. The rewriter cache is created
    # here so a supervised process owns it, rather than the first query to want it.
    AlexClaw.Config.init()
    QueryRewriter.init_cache()
    # 2. Seed defaults (marks sensitive keys, encrypts new values)
    Seeder.seed()
    # 3. Encrypt any remaining plaintext sensitive values
    EncryptExisting.run()
    # 4. Reload ETS with decrypted values
    AlexClaw.Config.init()
    # 5. Seed default LLM providers (reads API keys from Config)
    unless Application.get_env(:alex_claw, :skip_provider_seed, false) do
      ProviderSeeder.seed()
    end

    # 6. Load self-awareness docs into knowledge base (background, non-blocking)
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      SelfAwareness.load()
    end)

    # 7. Subscribe to config changes for cross-node ETS sync
    AlexClaw.Config.subscribe()
    # 8. Report a configured shell allowlist that still grants what 0.3.22 dropped,
    #    and say so if the control plane is read-only for want of a second factor
    Process.send_after(self(), :audit_shell_allowlist, @audit_delay_ms)
    Process.send_after(self(), :report_second_factor, @audit_delay_ms)
    {:ok, %{}}
  catch
    :error, %Postgrex.Error{} = e ->
      Logger.warning("Config seeder skipped (DB not ready): #{Exception.message(e)}")
      {:ok, %{}}
  end

  @impl true
  def handle_info(:audit_shell_allowlist, state) do
    report_withdrawn(Shell.withdrawn_in_use())
    {:noreply, state}
  end

  def handle_info(:report_second_factor, state) do
    report_second_factor(SecondFactor.impl().configured?())
    {:noreply, state}
  end

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

  # Without a second factor nothing can be changed from the admin UI, so this
  # is a statement about what the instance can do, not a suggestion. Sent once
  # at boot, and only over a gateway that is already reachable — on an instance
  # with neither, the log is the only place left to say it.
  defp report_second_factor(true), do: :ok

  defp report_second_factor(false) do
    Logger.warning(
      "2FA is not configured: the admin control plane is read-only. " <>
        "Set it up under Services → Two-factor authentication.",
      auth: :config
    )

    notify_read_only(Router.active_gateways())
  end

  defp notify_read_only([]), do: :ok

  defp notify_read_only(_gateways) do
    Gateway.send_message(
      "Admin config is read-only until 2FA is configured: " <>
        "Services → Two-factor authentication, or /setup 2fa here"
    )

    :ok
  end

  # A configured allowlist is never overwritten — not by the seeder, and not by
  # the migration that narrowed untouched ones. Left alone is not the same as
  # left unsaid: the operator decides, but should know what the list still grants.
  defp report_withdrawn([]), do: :ok

  defp report_withdrawn(prefixes) do
    named = Enum.join(prefixes, ", ")

    Logger.warning(
      "shell.whitelist still allows prefixes the default dropped in 0.3.22: #{named}. " <>
        "The configured list was left as it is — review it in Admin > Config.",
      auth: :config
    )

    Gateway.send_message(
      "⚠️ `shell.whitelist` still allows prefixes withdrawn in 0.3.22: #{named}\n\n" <>
        "Your configured list was kept as-is. Review it in Admin > Config."
    )

    :ok
  end
end
