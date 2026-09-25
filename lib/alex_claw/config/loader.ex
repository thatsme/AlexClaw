defmodule AlexClaw.Config.Loader do
  @moduledoc """
  Initializes the Config ETS table on application start.
  """
  use GenServer
  require Logger
  alias AlexClaw.Auth.SecondFactor
  alias AlexClaw.Config.Seeder
  alias AlexClaw.Gateway
  alias AlexClaw.Gateway.Router
  alias AlexClaw.Knowledge.SelfAwareness
  alias AlexClaw.LLM.ProviderSeeder
  alias AlexClaw.RAG.QueryRewriter
  alias AlexClaw.Repo
  alias AlexClaw.Skills.Shell
  alias Ecto.Adapters.SQL

  # Long enough for the gateways to have started, since the report goes out over
  # one of them.
  @audit_delay_ms :timer.seconds(15)

  @probe_backoff_ms [1_000, 2_000, 5_000]
  @probe_interval_ms 5_000
  @probe_budget_ms :timer.seconds(60)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # 0. Ensure skills directory exists
    skills_dir = Application.get_env(:alex_claw, :skills_dir, "/app/skills")
    File.mkdir_p!(skills_dir)

    boot(await_database(0, 0, budget_ms(opts)))
  end

  defp boot(:ok) do
    # 1. Create ETS tables and load raw DB values. The rewriter cache is created
    # here so a supervised process owns it, rather than the first query to want it.
    AlexClaw.Config.init()
    QueryRewriter.init_cache()
    # 2. Seed defaults (marks sensitive keys). Nothing is encrypted since 0.4.0
    #    (S7): a credential is in OpenBao, never in this table.
    Seeder.seed()
    # 3. Reload ETS with the seeded values
    AlexClaw.Config.init()
    # 4. Seed default LLM providers (reads API keys from Config)
    unless Application.get_env(:alex_claw, :skip_provider_seed, false) do
      ProviderSeeder.seed()
    end

    # 5. Load self-awareness docs into knowledge base (background, non-blocking)
    Task.Supervisor.start_child(AlexClaw.TaskSupervisor, fn ->
      SelfAwareness.load()
    end)

    # 6. Subscribe to config changes for cross-node ETS sync
    AlexClaw.Config.subscribe()
    # 7. Report a configured shell allowlist that still grants what 0.3.22 dropped,
    #    and say so if the control plane is read-only for want of a second factor
    Process.send_after(self(), :audit_shell_allowlist, @audit_delay_ms)
    Process.send_after(self(), :report_second_factor, @audit_delay_ms)
    {:ok, %{}}
  catch
    :error, %Postgrex.Error{} = e ->
      Logger.warning("Config seeder skipped (DB not ready): #{Exception.message(e)}")
      {:ok, %{}}
  end

  defp boot({:error, :database_unavailable}) do
    Logger.error(
      "The database did not answer. AlexClaw does not start without its configuration — " <>
        "an agent running on defaults nobody chose is worse than one that does not run. " <>
        "Check DATABASE_HOSTNAME, DATABASE_USERNAME, DATABASE_PASSWORD and DATABASE_NAME, " <>
        "and that the database is reachable from this container."
    )

    {:stop, :database_unavailable}
  end

  # Blocking, and deliberately so. The configuration is a hard dependency of
  # everything else — an agent running on defaults nobody chose is worse than
  # one that does not run — so this waits here rather than retrying in the
  # background the way SkillRegistry and UsageTracker do. Those can work
  # without what they were going to load. This cannot.
  #
  # Bounded, and deliberately so. An unbounded wait is a container that never
  # reports unhealthy and never restarts, which is harder to diagnose than a
  # clear stop. 1s, 2s, 5s, then every 5s, up to a minute.
  #
  # The compose files also make the app wait on a healthy database, so in an
  # ordinary deployment this never has to wait at all. It is here for the
  # deployments that do not — swarm ignores depends_on, and an external
  # database has no healthcheck to depend on.
  defp await_database(attempt, waited, budget) do
    probe(database_answered?(), attempt, waited, budget)
  end

  defp probe(true, _attempt, _waited, _budget), do: :ok

  defp probe(false, _attempt, waited, budget) when waited >= budget do
    {:error, :database_unavailable}
  end

  defp probe(false, attempt, waited, budget) do
    delay = probe_delay(attempt)
    announce_wait(attempt)
    Process.sleep(delay)
    await_database(attempt + 1, waited + delay, budget)
  end

  # Said once. A line per attempt would bury the error that follows it.
  defp announce_wait(0), do: Logger.info("Waiting for the database before loading configuration")
  defp announce_wait(_attempt), do: :ok

  defp probe_delay(attempt) when attempt < length(@probe_backoff_ms) do
    Enum.at(@probe_backoff_ms, attempt)
  end

  defp probe_delay(_attempt), do: @probe_interval_ms

  defp budget_ms(opts) when is_list(opts),
    do: Keyword.get(opts, :database_wait_ms, @probe_budget_ms)

  defp budget_ms(_opts), do: @probe_budget_ms

  # Any failure is the same answer — no. The reason is not lost: waiting is
  # announced once and a wait that runs out is logged with what to check.
  defp database_answered? do
    match?({:ok, _result}, SQL.query(Repo, "SELECT 1", []))
  rescue
    _error -> false
  catch
    :exit, _reason -> false
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

  # The flag is on and nothing is behind it. Reported separately because the
  # remedy is different: this instance was set up once and has lost the secret,
  # so "set it up" means enrol again, and the flag is repaired so the setup
  # screen is reachable at all.
  defp report_second_factor(false) do
    report_absent(SecondFactor.impl().misconfigured?())
  end

  # The instance is claiming a factor it cannot supply. Reported and not
  # repaired: withdrawing the flag here would be acting on "no secret" when
  # what is known is "no secret this code can see", and that distinction is
  # exactly what went wrong the first time.
  defp report_absent(true) do
    Logger.warning(
      "2FA is enabled but no secret is stored; set it up again under Services. " <>
        "The control plane stays read-only until a second factor can answer.",
      auth: :config
    )

    notify_read_only(Router.active_gateways())
  end

  defp report_absent(false) do
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
