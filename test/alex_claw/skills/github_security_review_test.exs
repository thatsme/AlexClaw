defmodule AlexClaw.Skills.GitHubSecurityReviewTest do
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.GitHubSecurityReview

  # Every test here must be decided before any request leaves the node. The API
  # base points at a Bypass with nothing stubbed: a request to any path fails
  # the test when Bypass exits. (The old "neither pr_number nor commit_sha" test
  # made a real call to api.github.com.)
  setup do
    bypass = Bypass.open()
    Application.put_env(:alex_claw, :github_api_base, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:alex_claw, :github_api_base) end)
    %{bypass: bypass}
  end

  describe "run/1 refuses before any request" do
    test "no repository configured" do
      assert {:error, :no_repo_configured} = GitHubSecurityReview.run(%{config: %{}})
    end

    test "an empty repository string" do
      assert {:error, :no_repo_configured} =
               GitHubSecurityReview.run(%{config: %{"repo" => ""}})
    end

    test "specific_pr without a PR number" do
      insert_setting("github.token", "fake-token", type: "string", category: "github")

      assert {:error, :no_target} =
               GitHubSecurityReview.run(%{
                 config: %{"repo" => "owner/repo", "mode" => "specific_pr"}
               })
    end

    test "specific_commit without a commit" do
      insert_setting("github.token", "fake-token", type: "string", category: "github")

      assert {:error, :no_target} =
               GitHubSecurityReview.run(%{
                 config: %{"repo" => "owner/repo", "mode" => "specific_commit"}
               })
    end

    test "a repository that is not owner/name" do
      insert_setting("github.token", "fake-token", type: "string", category: "github")

      assert {:error, :invalid_target} =
               GitHubSecurityReview.run(%{
                 config: %{"repo" => "../user", "mode" => "specific_pr", "pr_number" => 7}
               })
    end
  end

  describe "behaviour" do
    test "description returns a string" do
      assert is_binary(GitHubSecurityReview.description())
    end

    test "routes returns expected branches" do
      routes = GitHubSecurityReview.routes()
      assert :on_diff in routes
      assert :on_empty in routes
      assert :on_error in routes
    end
  end
end
