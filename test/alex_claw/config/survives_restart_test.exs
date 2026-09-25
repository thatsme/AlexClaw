defmodule AlexClaw.Config.SurvivesRestartTest do
  @moduledoc """
  An enrolled second factor survives a restart.

  Nobody was asserting this, and for months it was false: seeding wrote an empty
  default over the TOTP secret on every boot, so enrolling two-factor
  authentication and restarting the container lost it. The seeder fix has a
  mutation test of its own, but that tests the cause. This tests the thing
  anyone actually cares about, in the words they would use.

  A container restart is not available here, so this runs the boot sequence
  `Config.Loader` runs — the real functions, in the real order, not a
  rehearsal of them. `boot_steps/0` below is a copy of that sequence, which is
  two copies of one fact, so the last test in this file fails if the loader
  grows a step this one does not perform.

  What it cannot cover: anything outside those steps. A restart also reloads
  the VM, re-reads the environment and re-runs migrations. If a future fault
  lives there, this will not see it.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{Elevation, SecondFactor, TOTP}
  alias AlexClaw.Config
  alias AlexClaw.Config.{Seeder, Setting}

  # A fresh secret per test: OpenBao remembers the codes it accepted, across
  # tests (0.4.0 S6).
  defp enrol do
    secret = Base.encode32(NimbleTOTP.secret(), padding: false)
    Config.set("auth.totp.secret", secret, type: "string", category: "auth", sensitive: true)
    Config.set("auth.totp.enabled", "true", type: "boolean", category: "auth")
    secret
  end

  defp current_code(secret),
    do: secret |> Base.decode32!(padding: false) |> NimbleTOTP.verification_code()

  # The steps AlexClaw.Config.Loader performs on the way up, minus the ones
  # that only schedule work for later.
  defp boot do
    Config.init()
    Seeder.seed()
    Config.init()
    :ok
  end

  # Since 0.4.0 (S6) the key is kept by OpenBao, not read back from the
  # database: what must survive is that the enrolment still answers.
  test "an enrolled secret is still there after a boot" do
    secret = enrol()
    assert TOTP.configured?()

    boot()

    assert TOTP.verify(current_code(secret)), "booting erased the second factor"
    assert Elevation.configured?(), "the instance came up unable to verify a code"
  end

  # Once could be luck — a value that survives the first pass and is eaten by
  # the second. The fault this guards against happened on *every* boot.
  test "and after another one" do
    secret = enrol()

    boot()
    boot()
    boot()

    assert TOTP.verify(current_code(secret))
    assert Elevation.configured?()
  end

  test "the enabled flag survives too, so the instance does not quietly disarm" do
    enrol()

    boot()

    assert Config.enabled?("auth.totp.enabled")
    refute SecondFactor.impl().misconfigured?()
  end

  # The row is what a restart actually reloads from. Asserting through the
  # accessor alone would pass on a cached value that the database no longer has.
  test "the stored row still holds a secret, not an empty default" do
    enrol()

    boot()

    row = Repo.get_by(Setting, key: "auth.totp.secret")

    assert row, "the row was deleted"
    refute row.value in [nil, ""], "the row was emptied, which is how this failed before"
  end

  # boot/0 above is a second copy of the loader's sequence. This fails when the
  # loader grows a step that copy does not have, because a boot test that
  # simulates the wrong boot is worse than none.
  test "the simulated boot still matches the loader's" do
    body =
      "lib/alex_claw/config/loader.ex"
      |> File.read!()
      |> String.split("defp boot(:ok) do", parts: 2)
      |> List.last()
      |> String.split("\n  end", parts: 2)
      |> List.first()

    # EncryptExisting.run() left the loader in 0.4.0 (S7): nothing is encrypted.
    performed = ["AlexClaw.Config.init()", "Seeder.seed()"]

    for call <- performed do
      assert String.contains?(body, call),
             "the loader no longer calls #{call}, so this file simulates a boot that does not happen"
    end

    # Steps the loader takes that this file deliberately does not. Each is
    # named rather than the check being loosened, so a new step still has to
    # justify itself here before this test will pass.
    #
    #   QueryRewriter.init_cache  creates an ETS table and writes no setting;
    #                             also not re-entrant, so a test cannot run it
    #                             twice the way it runs the rest
    #   SelfAwareness.load        runs in a task, loads documents into the
    #                             knowledge base, touches no setting
    #   Task.Supervisor/send_after/subscribe
    #                             schedule or subscribe; nothing is written
    #   Logger.warning            the catch clause, not a boot step
    deferred = [
      "QueryRewriter.init_cache()",
      "SelfAwareness.load()",
      "Task.Supervisor.start_child",
      "Process.send_after",
      "subscribe()",
      "Logger.warning"
    ]

    others =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&Regex.match?(~r/^[A-Z][A-Za-z.]*\.[a-z_]+\(|^unless /, &1))
      |> Enum.reject(fn line ->
        Enum.any?(
          performed ++ deferred ++ ["ProviderSeeder.seed()", "unless "],
          &String.contains?(line, &1)
        )
      end)

    assert others == [],
           """
           The loader's boot does something this test does not simulate:
             #{Enum.join(others, "\n  ")}

           Add it to boot/0 here, or say why it cannot touch configuration.
           """
  end
end
