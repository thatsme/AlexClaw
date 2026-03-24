defmodule AlexClaw.Google.TokenManagerTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Google.TokenManager

  describe "get_token/0" do
    test "returns error when not configured" do
      assert {:error, :not_configured} = TokenManager.get_token()
    end
  end

  describe "status/0" do
    test "returns status without crashing" do
      status = TokenManager.status()
      assert status == :not_configured or is_map(status)
    end
  end

  describe "refresh/0" do
    test "returns error when no refresh token" do
      result = TokenManager.refresh()
      assert {:error, _} = result
    end
  end
end
