defmodule AlexClaw.DataCase do
  @moduledoc """
  Test case for modules that require database access.
  Sets up Ecto sandbox and ETS tables.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias AlexClaw.Repo
      import Ecto
      import Ecto.Query
      import AlexClaw.DataCase
      import AlexClaw.BypassHelper
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(AlexClaw.Repo, shared: not tags[:async])

    # Drained first: a supervised audit task still holding the connection when
    # the owner is stopped fails whichever test runs next.
    on_exit(fn ->
      AlexClaw.TaskDrain.drain()
      Sandbox.stop_owner(pid)
    end)

    # Values resolved by earlier tests are masked from then on (Secrets.Mask),
    # in every text: one test's weak value would mangle another's. Each test
    # starts with none remembered.
    forget_masked_values()

    # Ensure ETS tables exist for Config and LLM usage
    ensure_ets_table(:alexclaw_config)
    ensure_ets_table(:alexclaw_llm_usage)

    # Seed minimal identity config so Identity.system_prompt/1 doesn't crash
    seed_identity_config()

    :ok
  end

  defp ensure_ets_table(name) do
    case :ets.info(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set])
      _ -> :ets.delete_all_objects(name)
    end
  end

  defp seed_identity_config do
    AlexClaw.Config.set("identity.name", "TestAgent", type: "string", category: "identity")

    AlexClaw.Config.set("identity.base_prompt", "You are {name}, a test assistant.",
      type: "string",
      category: "identity"
    )
  end

  @doc "Helper to create or update a config setting."
  def insert_setting(key, value, opts \\ []) do
    type = Keyword.get(opts, :type, "string")
    category = Keyword.get(opts, :category, "general")

    {:ok, setting} = AlexClaw.Config.set(key, value, type: type, category: category)
    setting
  end

  defp forget_masked_values do
    if :ets.whereis(:alexclaw_secret_mask) != :undefined,
      do: :ets.delete_all_objects(:alexclaw_secret_mask)
  end
end
