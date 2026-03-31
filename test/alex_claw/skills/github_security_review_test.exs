defmodule AlexClaw.Skills.GitHubSecurityReviewTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.GitHubSecurityReview

  describe "run/1" do
    test "returns error when no repo configured" do
      assert {:error, :no_repo_configured} = GitHubSecurityReview.run(%{config: %{}})
    end

    test "returns error with empty repo string" do
      assert {:error, :no_repo_configured} = GitHubSecurityReview.run(%{config: %{"repo" => ""}})
    end

    test "returns error when neither pr_number nor commit_sha provided" do
      insert_setting("github.default_repo", "owner/repo", type: "string", category: "github")
      insert_setting("github.token", "fake-token", type: "string", category: "github")

      result = GitHubSecurityReview.run(%{config: %{"repo" => "owner/repo"}})
      assert {:error, _reason} = result
    end
  end

  describe "behaviour" do
    test "description returns a string" do
      assert is_binary(GitHubSecurityReview.description())
    end

    test "routes returns expected branches" do
      routes = GitHubSecurityReview.routes()
      assert :on_clean in routes
      assert :on_findings in routes
      assert :on_error in routes
    end
  end
end
