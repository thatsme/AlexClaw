defmodule AlexClawWeb.AdminLive.PoliciesTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  describe "mount" do
    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/policies")
      assert redirected_to(conn) == "/login"
    end

    test "renders when authenticated", %{conn: conn} do
      conn = conn |> authenticate() |> get("/policies")
      assert html_response(conn, 200) =~ "Policies"
    end
  end
end
