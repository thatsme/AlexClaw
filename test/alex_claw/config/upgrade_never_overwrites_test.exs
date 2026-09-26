defmodule AlexClaw.Config.UpgradeNeverOverwritesTest do
  @moduledoc """
  The 0.4.0 upgrade never overwrites a value OpenBao already holds, and a
  parked setting never lands on another secret's name (S8 H5, H6; "no
  credential may be lost in the upgrade").

  - A sensitive setting the admin added in 0.3.x is parked in its own
    namespace, `parked_…`, one name per key: it can collide neither with a
    declared secret (`github_token` against `github.token`) nor with another
    custom key (`custom.token` against `custom_token`).
  - When the name a 0.3.x value would move to already holds another value —
    the admin entered a new one in 0.4.0 after a first start that could not
    reach OpenBao — the value in OpenBao is kept, the 0.3.x row is left as it
    was, and the upgrade reports the conflict by name. The same value already
    there is not a conflict: the move completes.
  - An LLM provider whose credentials were re-entered in 0.4.0 keeps them; its
    0.3.x key is not moved over them, and the conflict is reported.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.{Config, LLM, Secrets}
  alias AlexClaw.Config.SecretUpgrade
  alias AlexClaw.LLM.{Client, Provider}
  alias AlexClawTest.Legacy

  # OpenBao keeps what earlier tests stored; the upgrade never overwrites it.
  setup do
    Legacy.clear_declared_secrets()
  end

  @declared "ghp-declared-#{System.unique_integer([:positive])}"
  @custom "custom-value-#{System.unique_integer([:positive])}"
  @other "other-value-#{System.unique_integer([:positive])}"

  defp db_value(key) do
    %{rows: rows} = Repo.query!("SELECT value FROM settings WHERE key = $1", [key])
    rows |> List.flatten() |> List.first()
  end

  defp failed_keys(report), do: Enum.map(report.failed, &elem(&1, 0))

  defp conflict?(report, key),
    do: Enum.any?(report.failed, &match?({^key, {:conflict, _name}}, &1))

  defp down_vault do
    config = Application.fetch_env!(:alex_claw, AlexClaw.Vault)
    down = :"vault_down_#{System.unique_integer([:positive])}"

    start_supervised!(
      {AlexClaw.Vault, Keyword.merge(config, address: "https://127.0.0.1:1", name: down)}
    )

    down
  end

  describe "a parked setting" do
    test "does not overwrite the declared secret its name resembles" do
      Legacy.insert_setting("github.token", @declared, encrypted: true)
      Legacy.insert_setting("github_token", @custom, encrypted: true)

      assert {:ok, report} = SecretUpgrade.run()

      assert {:ok, @declared} = Config.secret("github.token", for: "host:api.github.com")
      refute Secrets.get("setting_github_token").binding == ["inbound:carried_over"]

      assert [{"github_token", parked}] = report.custom_moved
      assert String.starts_with?(parked, "parked_")
      assert Secrets.value_matches?(parked, @custom)
    end

    test "does not share a name with another custom key" do
      Legacy.insert_setting("custom.token", @custom, encrypted: true)
      Legacy.insert_setting("custom_token", @other, encrypted: true)

      assert {:ok, report} = SecretUpgrade.run()

      names = Map.new(report.custom_moved)
      assert map_size(names) == 2
      assert names["custom.token"] != names["custom_token"]
      assert Secrets.value_matches?(names["custom.token"], @custom)
      assert Secrets.value_matches?(names["custom_token"], @other)
    end
  end

  describe "a value OpenBao already holds" do
    test "is kept; the 0.3.x row is left as it was and the conflict reported" do
      {:ok, _} = Config.set("telegram.bot_token", "123:entered-in-0.4.0")
      Legacy.insert_setting("telegram.bot_token", "123:left-by-0.3", encrypted: true)
      before = db_value("telegram.bot_token")

      assert {:ok, report} = SecretUpgrade.run()

      assert {:ok, "123:entered-in-0.4.0"} =
               Config.secret("telegram.bot_token",
                 for: Config.secret_binding("telegram.bot_token")
               )

      assert conflict?(report, "telegram.bot_token")
      assert db_value("telegram.bot_token") == before
      assert Legacy.decrypt_setting("telegram.bot_token") == "123:left-by-0.3"
    end

    test "the same value is not a conflict: the move completes" do
      {:ok, _} = Config.set("telegram.bot_token", "123:same-value")
      Legacy.insert_setting("telegram.bot_token", "123:same-value", encrypted: true)

      assert {:ok, report} = SecretUpgrade.run()

      assert "telegram.bot_token" in report.moved
      refute "telegram.bot_token" in failed_keys(report)
      assert db_value("telegram.bot_token") in [nil, ""]
    end
  end

  describe "an LLM provider re-entered after a first start without OpenBao" do
    test "keeps the credentials entered in 0.4.0; the 0.3.x key is not moved over them" do
      id =
        Legacy.insert_provider(%{
          host: "https://llm.example.com",
          api_key: "sk-left-by-0.3",
          headers: %{"x-org" => "org-old"}
        })

      assert {:ok, first} = SecretUpgrade.run(vault: down_vault())
      assert "provider #{id}" in failed_keys(first)

      provider = Repo.get!(Provider, id)
      {:ok, _} = LLM.update_provider(provider, %{api_key: "sk-entered-in-0.4.0"})

      assert {:ok, report} = SecretUpgrade.run()

      assert Client.resolve_api_key(Repo.get!(Provider, id)) == "sk-entered-in-0.4.0"
      assert Enum.any?(report.failed, &match?({"provider " <> _, {:conflict, _}}, &1))

      %{rows: [[api_key]]} = Repo.query!("SELECT api_key FROM llm_providers WHERE id = $1", [id])
      assert Legacy.open(api_key) == "sk-left-by-0.3", "the 0.3.x key was dropped"
    end
  end
end
