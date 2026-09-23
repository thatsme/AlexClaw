defmodule AlexClaw.Skills.GitHubSecurityReviewTargetTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Skills.GitHubSecurityReview

  # F7: what to review is resolved from ONE source — the run input when it is a
  # webhook event naming a repository, otherwise the step config. Never a repo
  # from one and a PR number from the other.
  #
  # Whatever the source, the target is interpolated into a GitHub API path and
  # sent with the instance's token. It is validated before any request: a
  # repository is exactly `owner/name`, a PR number a positive integer, a commit
  # a hex SHA of 7–40 characters.

  describe "from the run input (a webhook event)" do
    test "a pull request event gives its repository and number" do
      args = %{
        config: %{},
        input: %{"event" => "pull_request", "repo" => "owner/repo", "pr_number" => 7}
      }

      assert {:ok, %{repo: "owner/repo", pr_number: 7}} = GitHubSecurityReview.target(args)
    end

    test "a push event gives its repository and commit" do
      args = %{
        config: %{},
        input: %{"event" => "push", "repo" => "owner/repo", "commit_sha" => "096ee22"}
      }

      assert {:ok, %{repo: "owner/repo", commit_sha: "096ee22"}} =
               GitHubSecurityReview.target(args)
    end

    test "the event wins over a repository pinned in the step config" do
      args = %{
        config: %{"repo" => "pinned/other", "pr_number" => 99},
        input: %{"event" => "pull_request", "repo" => "owner/repo", "pr_number" => 7}
      }

      assert {:ok, target} = GitHubSecurityReview.target(args)
      assert target == %{repo: "owner/repo", pr_number: 7}
    end

    test "an event without a PR number or commit is refused, not completed from config" do
      args = %{
        config: %{"pr_number" => 99, "commit_sha" => "deadbeef"},
        input: %{"event" => "pull_request", "repo" => "owner/repo"}
      }

      assert {:error, :no_target} = GitHubSecurityReview.target(args)
    end

    test "a PR number given as a string of digits is normalised" do
      args = %{
        config: %{},
        input: %{"event" => "pull_request", "repo" => "owner/repo", "pr_number" => "7"}
      }

      assert {:ok, %{pr_number: 7}} = GitHubSecurityReview.target(args)
    end

    test "an event's repository is validated like any other" do
      args = %{
        config: %{"repo" => "owner/repo", "pr_number" => 3},
        input: %{"event" => "pull_request", "repo" => "../user", "pr_number" => 7}
      }

      assert {:error, :invalid_target} = GitHubSecurityReview.target(args)
    end
  end

  describe "from the step config (no event)" do
    test "an explicit repository and PR number" do
      args = %{config: %{"repo" => "owner/repo", "pr_number" => 3}, input: nil}

      assert {:ok, %{repo: "owner/repo", pr_number: 3}} = GitHubSecurityReview.target(args)
    end

    test "input that is not an event map is ignored" do
      args = %{
        config: %{"repo" => "owner/repo", "commit_sha" => "abc1234"},
        input: "text produced by a previous step"
      }

      assert {:ok, %{repo: "owner/repo", commit_sha: "abc1234"}} =
               GitHubSecurityReview.target(args)
    end

    test "no repository anywhere" do
      assert {:error, :no_repo_configured} =
               GitHubSecurityReview.target(%{config: %{}, input: nil})
    end

    test "an empty repository is no repository" do
      assert {:error, :no_repo_configured} =
               GitHubSecurityReview.target(%{config: %{"repo" => ""}, input: nil})
    end
  end

  describe "a target that is not a plain GitHub path is refused" do
    for repo <- [
          "owner",
          "owner/repo/extra",
          "../user",
          "owner/..",
          "./repo",
          "/owner/repo",
          "owner/repo?per_page=100",
          "owner/repo#x",
          "owner/re po",
          "owner/repo%2F..",
          "owner\\repo"
        ] do
      test "repository #{inspect(repo)}" do
        args = %{config: %{"repo" => unquote(repo), "pr_number" => 7}, input: nil}
        assert {:error, :invalid_target} = GitHubSecurityReview.target(args)
      end
    end

    for pr <- ["7/../../user", "7abc", " 7", "0", "-1", 0, -3, 7.0, "7.0"] do
      test "PR number #{inspect(pr)}" do
        args = %{config: %{"repo" => "owner/repo", "pr_number" => unquote(pr)}, input: nil}
        assert {:error, :invalid_target} = GitHubSecurityReview.target(args)
      end
    end

    for sha <- [
          "abc12",
          "zzzzzzz",
          "HEAD",
          "main",
          "096ee22/../../user",
          "096ee22?x=1",
          String.duplicate("a", 41)
        ] do
      test "commit #{inspect(sha)}" do
        args = %{config: %{"repo" => "owner/repo", "commit_sha" => unquote(sha)}, input: nil}
        assert {:error, :invalid_target} = GitHubSecurityReview.target(args)
      end
    end
  end
end
