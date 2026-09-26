defmodule AlexClaw.Database.RestoreKeepsIdentityTest do
  @moduledoc """
  A restore never replaces who the admin is (S8 H4; THREAT_MODEL P4).

  Identity state is the admin password's hash, the second factor's settings
  (`auth.totp.*`) and the recovery codes; the sign-ins were never part of a
  restore. A restore keeps this installation's, whatever the file holds: a
  crafted file cannot plant a TOTP secret, a password hash or recovery codes,
  and a genuine older backup cannot bring back codes since used or replaced.
  The file's copies are skipped, and the result says what was kept.

  An export does not carry identity state either: it could never be restored.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AdminPassword, RecoveryCodes}
  alias AlexClaw.Database.{DataExport, DataSet, Restore}

  @planted_code "AAAAA-BBBBB"

  defp export do
    ""
    |> DataExport.write(fn data, acc -> [acc, data] end)
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end

  defp identity do
    %{rows: settings} =
      Repo.query!(
        "SELECT key, value FROM settings " <>
          "WHERE key = 'auth.admin_password_hash' OR key LIKE 'auth.totp.%' ORDER BY key"
      )

    %{rows: codes} = Repo.query!("SELECT hash, used_at FROM auth_recovery_codes ORDER BY hash")
    {settings, codes}
  end

  # A settings row shaped like the file's own, carrying `key` and `value`, in
  # place of the file's row for `key` if it has one.
  defp with_setting(data, key, value) do
    %{"columns" => columns, "rows" => [template | _] = rows} = data["tables"]["settings"]
    names = Enum.map(columns, &column_name/1)

    row =
      names
      |> Enum.zip(template)
      |> Enum.map(fn
        {"id", _} -> Integer.to_string(900_000 + System.unique_integer([:positive]))
        {"key", _} -> key
        {"value", _} -> value
        {_name, v} -> v
      end)

    key_at = Enum.find_index(names, &(&1 == "key"))
    others = Enum.reject(rows, &(Enum.at(&1, key_at) == key))
    put_in(data, ["tables", "settings", "rows"], others ++ [row])
  end

  defp column_name([name | _]), do: name
  defp column_name(%{"name" => name}), do: name
  defp column_name(name) when is_binary(name), do: name

  # The recovery codes table as a 0.3.x-0.4.0 export held it, with one code
  # the attacker knows, hashed the legacy way.
  defp with_recovery_codes(data, template_columns) do
    digest =
      :sha256
      |> :crypto.hash(@planted_code)
      |> Base.encode16(case: :lower)

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    row =
      Enum.map(DataSet.columns("auth_recovery_codes"), fn
        {"id", _} -> "1"
        {"hash", _} -> digest
        {"used_at", _} -> nil
        {_name, _type} -> now
      end)

    put_in(data, ["tables", "auth_recovery_codes"], %{
      "columns" => template_columns,
      "rows" => [row]
    })
  end

  defp live_identity do
    AdminPassword.store(AdminPassword.hash("the-admin-#{System.unique_integer()}"))
    insert_setting("restore.probe", "live")
    RecoveryCodes.generate()
  end

  describe "a restore file carrying identity state" do
    test "does not replace the admin's password hash, second factor or recovery codes" do
      codes = live_identity()
      before = identity()
      data = export()

      columns = Enum.map(DataSet.columns("auth_recovery_codes"), &elem(&1, 0))

      tampered =
        data
        |> with_setting("auth.admin_password_hash", AdminPassword.hash("attacker"))
        |> with_setting("auth.totp.secret", "JBSWY3DPEHPK3PXP")
        |> with_setting("auth.totp.enabled", "true")
        |> with_recovery_codes(columns)

      assert {:ok, message} = Restore.load(tampered)

      assert identity() == before, "the restore replaced identity state"
      assert {:error, :invalid_code} = RecoveryCodes.redeem(@planted_code)
      assert RecoveryCodes.valid?(hd(codes)), "the admin's own codes were lost"

      assert message =~ "admin password"
      assert message =~ "second factor"
      assert message =~ "recovery codes"
    end

    test "restores the rest of the settings" do
      live_identity()
      data = export()
      insert_setting("restore.probe", "changed after the export")

      assert {:ok, _message} = Restore.load(data)

      assert %{rows: [["live"]]} =
               Repo.query!("SELECT value FROM settings WHERE key = 'restore.probe'")
    end
  end

  test "an export carries no identity state" do
    live_identity()
    data = export()

    refute Map.has_key?(data["tables"], "auth_recovery_codes")

    %{"columns" => columns, "rows" => rows} = data["tables"]["settings"]
    key_at = Enum.find_index(columns, &(column_name(&1) == "key"))
    keys = Enum.map(rows, &Enum.at(&1, key_at))

    refute "auth.admin_password_hash" in keys
    refute Enum.any?(keys, &String.starts_with?(&1, "auth.totp."))
  end
end
