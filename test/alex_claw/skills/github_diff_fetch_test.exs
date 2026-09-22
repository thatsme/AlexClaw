defmodule AlexClaw.Skills.GitHubDiffFetchTest do
  @moduledoc """
  A pull request's diff is fetched with the diff media type. The request used
  to carry two Accept headers, JSON first; GitHub answered with the PR's JSON,
  a 200 the skill then reported as a failure, and no review was ever written.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration

  alias AlexClaw.Skills.GitHubSecurityReview

  setup do
    bypass = Bypass.open()
    Application.put_env(:alex_claw, :github_api_base, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:alex_claw, :github_api_base) end)
    %{bypass: bypass}
  end

  test "the PR diff is requested with one Accept header, the diff one", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/repos/me/repo/pulls/7", fn conn ->
      accepts = Plug.Conn.get_req_header(conn, "accept")

      if accepts == ["application/vnd.github.v3.diff"] do
        Plug.Conn.resp(conn, 200, "diff --git a/lib/x.ex b/lib/x.ex\n+secret = \"hardcoded\"\n")
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"title" => "Add x", "user" => %{"login" => "me"}, "accepts" => accepts})
        )
      end
    end)

    assert {:ok, output, :on_diff} =
             GitHubSecurityReview.run(%{
               config: %{"repo" => "me/repo", "mode" => "specific_pr", "pr_number" => 7}
             })

    assert output =~ "Add x"
    assert output =~ "+secret = \"hardcoded\""
  end
end
