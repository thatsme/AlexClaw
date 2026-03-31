defmodule AlexClawWeb.AdminLive.SkillsTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  describe "mount" do
    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/skills")
      assert redirected_to(conn) == "/login"
    end

    test "renders when authenticated", %{conn: conn} do
      conn = conn |> authenticate() |> get("/skills")
      assert html_response(conn, 200) =~ "Skills"
    end
  end
end
