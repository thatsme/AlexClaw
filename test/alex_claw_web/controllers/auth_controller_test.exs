defmodule AlexClawWeb.AuthControllerTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  describe "GET /login" do
    test "renders login page for unauthenticated user", %{conn: conn} do
      conn = get(conn, "/login")
      assert html_response(conn, 200) =~ "AlexClaw"
      assert html_response(conn, 200) =~ "Password"
    end

    test "redirects to / when already authenticated", %{conn: conn} do
      conn = conn |> authenticate() |> get("/login")
      assert redirected_to(conn) == "/"
    end
  end

  # Tests that change the admin password put back what was there — since
  # 0.4.0 config/test.exs sets one, and deleting it would leave every later
  # test in the run with none (an order-dependent failure in gate_audits_test).
  defp with_admin_password(value) do
    previous = Application.fetch_env(:alex_claw, :admin_password)
    Application.put_env(:alex_claw, :admin_password, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:alex_claw, :admin_password, v)
        :error -> Application.delete_env(:alex_claw, :admin_password)
      end
    end)
  end

  describe "POST /login" do
    test "returns 401 with invalid password", %{conn: conn} do
      with_admin_password("correct_password")

      conn = post(conn, "/login", %{"password" => "wrong_password"})
      assert html_response(conn, 401) =~ "Invalid password"
    end

    test "returns 401 when ADMIN_PASSWORD is not set", %{conn: conn} do
      with_admin_password(nil)

      conn = post(conn, "/login", %{"password" => "anything"})
      assert html_response(conn, 401) =~ "ADMIN_PASSWORD is not set"
    end

    test "redirects to / on successful login", %{conn: conn} do
      with_admin_password("test_pass_123")

      conn = post(conn, "/login", %{"password" => "test_pass_123"})
      assert redirected_to(conn) == "/"
    end
  end

  describe "POST /logout" do
    test "clears session and redirects to /login", %{conn: conn} do
      conn = conn |> authenticate() |> post("/logout")
      assert redirected_to(conn) == "/login"
    end
  end
end
