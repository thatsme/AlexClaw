defmodule AlexClaw.RepoTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  describe "Repo" do
    test "is running and connected" do
      assert {:ok, _} = Ecto.Adapters.SQL.query(AlexClaw.Repo, "SELECT 1")
    end

    test "can perform basic queries" do
      result = AlexClaw.Repo.query!("SELECT current_database()")
      assert result.num_rows == 1
    end
  end
end
