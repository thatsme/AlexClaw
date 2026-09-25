defmodule AlexClawWeb.AdminPasswordTest do
  @moduledoc """
  The admin password is kept as a salted, slow hash, never as the password
  (V040_SECURITY_DESIGN.md §6; reports/S6_PREMISES.md §2; 0.4.0 S6).

  - The hash is PBKDF2-HMAC-SHA256 with 600,000 iterations and a random salt,
    computed with OTP's own `:crypto`. It is local, not in OpenBao: logging in
    has to work while OpenBao is sealed, which is when the operator needs the
    admin UI most.
  - `ADMIN_PASSWORD` is where the first password comes from. The first
    successful login stores its hash, and from then on the variable is
    ignored: changing it does not change the password.
  - A login made under one hash ends when the hash changes.
  """
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  alias AlexClaw.Auth.{AdminPassword, Elevation, Sessions}
  alias AlexClaw.Config.{Seeder, Setting}
  alias AlexClaw.Repo

  setup do
    previous = Application.get_env(:alex_claw, :admin_password)
    Application.put_env(:alex_claw, :admin_password, "first-password")
    on_exit(fn -> Application.put_env(:alex_claw, :admin_password, previous) end)
    :ok
  end

  defp login(conn, password), do: post(conn, "/login", %{"password" => password})

  defp stored, do: Repo.get_by(Setting, key: "auth.admin_password_hash")

  describe "the hash" do
    test "is salted PBKDF2-HMAC-SHA256 with 600,000 iterations" do
      hash = AdminPassword.hash("correct horse")

      assert "$pbkdf2-sha256$600000$" <> _salt_and_key = hash

      refute AdminPassword.hash("correct horse") == hash,
             "the same password hashed twice alike: no salt"

      assert AdminPassword.verify("correct horse", hash)
      refute AdminPassword.verify("correct horsf", hash)
    end
  end

  describe "the first login" do
    test "stores the hash, never the password", %{conn: conn} do
      assert login(conn, "first-password").status == 302

      assert %Setting{value: "$pbkdf2-sha256$600000$" <> _ = value} = stored()
      refute value =~ "first-password"
    end
  end

  describe "once the hash is stored" do
    test "ADMIN_PASSWORD is ignored: changing it does not change the password", %{conn: conn} do
      assert login(conn, "first-password").status == 302

      Application.put_env(:alex_claw, :admin_password, "second-password")

      assert login(build_conn(), "second-password").status == 401
      assert login(build_conn(), "first-password").status == 302
    end

    test "a wrong password is refused", %{conn: conn} do
      assert login(conn, "first-password").status == 302
      assert login(build_conn(), "not-the-password").status == 401
    end
  end

  test "with no hash and no ADMIN_PASSWORD, the login says so", %{conn: conn} do
    Application.put_env(:alex_claw, :admin_password, nil)

    conn = login(conn, "anything")

    assert conn.status == 401
    assert conn.resp_body =~ "ADMIN_PASSWORD is not set"
  end

  # The steps AlexClaw.Config.Loader runs on the settings table at start, as
  # the loader has them: EncryptExisting is run only while the loader still
  # calls it (0.4.0 S7 retires it). survives_restart_test.exs pins that its
  # own copy of the sequence matches the loader's.
  defp boot do
    loader = File.read!("lib/alex_claw/config/loader.ex")
    AlexClaw.Config.init()
    Seeder.seed()

    encrypt_existing = Module.concat(AlexClaw.Config, EncryptExisting)
    if loader =~ "EncryptExisting.run()", do: encrypt_existing.run()

    AlexClaw.Config.init()
  end

  # A restart must keep the stored hash as it is: no fallback to
  # ADMIN_PASSWORD, and logins made before it stay valid.
  test "a restart keeps the stored hash: ADMIN_PASSWORD is still ignored", %{conn: conn} do
    assert login(conn, "first-password").status == 302
    %Setting{value: hash} = stored()
    sid = Elevation.new_sid()
    :ok = Sessions.open(sid)

    boot()

    assert AdminPassword.stored() == hash
    assert Sessions.valid?(sid), "a restart ended the login"

    Application.put_env(:alex_claw, :admin_password, "second-password")
    assert login(build_conn(), "second-password").status == 401
    assert login(build_conn(), "first-password").status == 302
  end

  # The hash stays out of the settings cache a skill reads through.
  test "the hash is not served through Config.get" do
    :ok = AdminPassword.store(AdminPassword.hash("one"))

    assert_raise ArgumentError, ~r/not served through Config.get/, fn ->
      AlexClaw.Config.get("auth.admin_password_hash")
    end
  end

  test "a login made under one hash ends when the hash changes" do
    :ok = AdminPassword.store(AdminPassword.hash("one"))
    sid = Elevation.new_sid()
    :ok = Sessions.open(sid)
    assert Sessions.valid?(sid)

    :ok = AdminPassword.store(AdminPassword.hash("two"))

    refute Sessions.valid?(sid)
  end
end
