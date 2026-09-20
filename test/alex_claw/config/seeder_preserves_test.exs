defmodule AlexClaw.Config.SeederPreservesTest do
  @moduledoc """
  Seeding defaults must never overwrite a value that is already there.

  It did, for one key, on every boot. The seeder asked `Config.get/2` whether a
  key was already set. `auth.totp.secret` is deliberately kept out of the config
  cache, so `get/2` answered nil — the same answer it gives for a key that does
  not exist — and the seeder wrote its default, an empty string, over the
  enrolled secret. Enrol two-factor authentication, restart the container, and
  it was gone.

  The instance was then left with `auth.totp.enabled = true` and nothing behind
  it: every code refused, and the setup screen hidden because the page asked the
  same question. No way back from the browser.

  Assertions read the row. Reading through `Config.get/2` is what hid this in
  the first place, and for the uncached keys it now raises rather than lie.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Config
  alias AlexClaw.Config.{Seeder, Setting}

  defp row(key), do: Repo.get_by(Setting, key: key)
  defp value(key), do: row(key) && row(key).value

  describe "a seed run over an instance that is already configured" do
    test "leaves the TOTP secret alone" do
      Config.set("auth.totp.secret", "JBSWY3DPEHPK3PXP",
        type: "string",
        category: "auth",
        sensitive: true
      )

      before = value("auth.totp.secret")
      assert before not in [nil, ""], "the fixture did not store a secret"

      Seeder.seed()

      assert value("auth.totp.secret") == before,
             "seeding erased the second factor, which is what happened on every restart"
    end

    test "leaves every other value alone too" do
      Config.set("identity.name", "Chosen", type: "string", category: "identity")
      Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")

      Seeder.seed()

      assert value("identity.name") == "Chosen"
      assert value("auth.totp.enabled") == "true"
    end

    # The narrow fix would have been to special-case this one key. The general
    # statement is the one worth keeping: a seed run writes defaults only where
    # there is nothing.
    test "changes nothing at all on a second run" do
      Seeder.seed()

      before = Repo.all(Setting) |> Map.new(&{&1.key, &1.value})

      Seeder.seed()

      after_run = Repo.all(Setting) |> Map.new(&{&1.key, &1.value})

      assert after_run == before
    end
  end

  describe "the keys the cache does not hold" do
    test "are unreachable through Config.get/2, rather than answering nil" do
      for key <- Config.uncached_keys() do
        assert_raise ArgumentError, ~r/not served through Config.get/, fn ->
          Config.get(key)
        end
      end
    end

    # Compared before to after rather than to the literal: these rows are marked
    # sensitive, so what lands in the column is ciphertext. What matters is that
    # seeding does not change it.
    test "are never written by the seeder's defaults" do
      for key <- Config.uncached_keys() do
        Config.set(key, "a value that must survive", type: "string", category: "auth")
        stored = value(key)

        assert stored not in [nil, ""], "the fixture did not store anything for #{key}"

        Seeder.seed()

        assert value(key) == stored,
               "#{key} is uncached, so the seeder cannot see it and must not write over it"
      end
    end
  end
end
