defmodule AlexClaw.Auth.RecoveryCodesTransitTest do
  @moduledoc """
  Recovery codes are kept as OpenBao transit HMACs of their SHA-256 digest
  (V040_SECURITY_DESIGN.md §6; reports/S6_PREMISES.md §2; 0.4.0 S6).

  Before 0.4.0 each code was stored as its unsalted SHA-256: a copy of the
  table was enough to brute-force the codes offline. Now the stored value is
  keyed by a transit key that never leaves OpenBao, and codes are checked by
  OpenBao, in constant time.

  The codes saved before 0.4.0 keep working: the stored digests are re-keyed
  at the first start, so no code has to be generated or saved again.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.{RecoveryCode, RecoveryCodes}
  alias AlexClaw.Config.SecretUpgrade

  defp digest(code), do: :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower)

  describe "generated codes" do
    test "are stored as OpenBao HMACs, never as the code's digest" do
      codes = RecoveryCodes.generate()
      stored = Repo.all(RecoveryCode) |> Enum.map(& &1.hash)

      assert length(stored) == length(codes)
      assert Enum.all?(stored, &String.starts_with?(&1, "vault:v"))

      for code <- codes do
        refute digest(code) in stored, "a code's plain SHA-256 is stored"
      end
    end

    test "a code is accepted once" do
      [code | _] = RecoveryCodes.generate()

      assert {:ok, 9} = RecoveryCodes.redeem(code)
      assert {:error, :invalid_code} = RecoveryCodes.redeem(code)
    end

    test "a code that was never issued is refused" do
      RecoveryCodes.generate()
      assert {:error, :invalid_code} = RecoveryCodes.redeem("AAAAA-AAAAA")
    end
  end

  describe "codes saved before 0.4.0" do
    setup do
      codes = ["ABCDE-FGHJK", "MNPQR-STVWX"]

      for code <- codes do
        Repo.insert!(%RecoveryCode{hash: digest(code), inserted_at: DateTime.utc_now(:second)})
      end

      %{codes: codes}
    end

    test "are re-keyed at the first start, and still work", %{codes: [first | _]} do
      assert {:ok, report} = SecretUpgrade.run()
      assert report.recovery_codes == 2

      assert Repo.all(RecoveryCode) |> Enum.all?(&String.starts_with?(&1.hash, "vault:v"))
      assert {:ok, 1} = RecoveryCodes.redeem(first)
    end

    test "re-keying twice changes nothing", %{codes: [_, second]} do
      {:ok, _report} = SecretUpgrade.run()
      assert {:ok, report} = SecretUpgrade.run()
      assert report.recovery_codes == 0
      assert {:ok, _left} = RecoveryCodes.redeem(second)
    end
  end
end
