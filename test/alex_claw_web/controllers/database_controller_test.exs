defmodule AlexClawWeb.DatabaseControllerTest do
  use AlexClawWeb.ConnCase, async: false
  @moduletag :integration

  describe "GET /database/download" do
    test "redirects to login when unauthenticated", %{conn: conn} do
      conn = get(conn, "/database/download")
      assert redirected_to(conn) == "/login"
    end

    # Authenticated download test omitted: pg_dump is not available in the
    # test container (Alpine build stage). The controller calls
    # System.find_executable("pg_dump") which returns nil, causing a crash.
    # This would need pg_dump installed in the test Docker image to work.
  end
end
