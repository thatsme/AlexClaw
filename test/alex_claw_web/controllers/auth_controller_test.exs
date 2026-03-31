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

  describe "POST /login" do
    test "returns 401 with invalid password", %{conn: conn} do
      Application.put_env(:alex_claw, :admin_password, "correct_password")
      on_exit(fn -> Application.delete_env(:alex_claw, :admin_password) end)

      conn = post(conn, "/login", %{"password" => "wrong_password"})
      assert html_response(conn, 401) =~ "Invalid password"
    end

    test "returns 401 when ADMIN_PASSWORD is not set", %{conn: conn} do
      Application.put_env(:alex_claw, :admin_password, nil)
      on_exit(fn -> Application.delete_env(:alex_claw, :admin_password) end)

      conn = post(conn, "/login", %{"password" => "anything"})
      assert html_response(conn, 401) =~ "ADMIN_PASSWORD is not set"
    end

    test "redirects to / on successful login", %{conn: conn} do
      Application.put_env(:alex_claw, :admin_password, "test_pass_123")
      on_exit(fn -> Application.delete_env(:alex_claw, :admin_password) end)

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
