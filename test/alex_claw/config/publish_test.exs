defmodule AlexClaw.Config.PublishTest do
  @moduledoc """
  A control-plane change persists inside its transaction and publishes after
  it commits. persist/3 and remove/1 touch the database and nothing else;
  publish/1 makes the cache and subscribers agree with the committed row,
  whatever the caller meant, however often it runs.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config

  setup do
    Config.subscribe()
    :ok
  end

  defp cached(key), do: :ets.lookup(:alexclaw_config, key)

  test "persist writes the database and tells nobody" do
    assert {:ok, _} = Config.persist("publish.persist", "one")

    assert cached("publish.persist") == []
    refute_received {:config_changed, "publish.persist", _}
    assert Repo.get_by(AlexClaw.Config.Setting, key: "publish.persist").value == "one"
  end

  test "publish caches and announces the committed value" do
    {:ok, _} = Config.persist("publish.value", "7", type: "integer")
    assert Config.publish("publish.value") == :ok

    assert Config.get("publish.value") == 7
    assert_received {:config_changed, "publish.value", 7}
  end

  # The point of re-reading: a publish after a rollback must announce what the
  # database holds, not what the rolled-back change tried to write.
  test "after a rollback, publish reflects the database, not the attempt" do
    {:ok, _} = Config.set("publish.rollback", "before")

    {:error, :rolled_back} =
      Repo.transaction(fn ->
        {:ok, _} = Config.persist("publish.rollback", "after")
        Repo.rollback(:rolled_back)
      end)

    :ok = Config.publish("publish.rollback")
    assert Config.get("publish.rollback") == "before"
  end

  test "publish is idempotent" do
    {:ok, _} = Config.persist("publish.twice", "x")
    :ok = Config.publish("publish.twice")
    first = cached("publish.twice")
    :ok = Config.publish("publish.twice")

    assert cached("publish.twice") == first
  end

  test "publish repairs a cache that has drifted from the database" do
    {:ok, _} = Config.set("publish.drift", "truth")
    :ets.insert(:alexclaw_config, {"publish.drift", "drifted", false})

    :ok = Config.publish("publish.drift")
    assert Config.get("publish.drift") == "truth"
  end

  test "remove deletes the row only; publish then drops it from the cache" do
    {:ok, _} = Config.set("publish.gone", "here")

    assert Config.remove("publish.gone") == {:ok, :removed}
    assert Config.get("publish.gone") == "here", "remove touched the cache"

    :ok = Config.publish("publish.gone")
    assert Config.get("publish.gone") == nil
    assert_received {:config_changed, "publish.gone", nil}
  end

  test "removing a key that is not there is not an error" do
    assert Config.remove("publish.never") == {:ok, :absent}
  end

  test "a sensitive value is stored encrypted and cached in plaintext" do
    {:ok, row} = Config.persist("publish.secret", "hunter2", sensitive: true)
    refute row.value == "hunter2"

    :ok = Config.publish("publish.secret")
    assert Config.get("publish.secret") == "hunter2"
    assert Config.sensitive?("publish.secret")
  end

  test "a key the cache never holds is announced, never with its value" do
    {:ok, _} = Config.persist("auth.totp.last_used_at", "12345")
    :ok = Config.publish("auth.totp.last_used_at")

    assert cached("auth.totp.last_used_at") == []
    assert_received {:config_changed, "auth.totp.last_used_at", nil}
  end
end
