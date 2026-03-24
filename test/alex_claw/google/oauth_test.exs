defmodule AlexClaw.Google.OAuthTest do
  use AlexClaw.DataCase, async: false

  alias AlexClaw.Google.OAuth

  describe "generate_auth_url/1" do
    test "returns error when client_id not configured" do
      assert {:error, :client_id_not_configured} = OAuth.generate_auth_url("12345")
    end

    test "returns URL when client_id is configured" do
      insert_setting("google.oauth.client_id", "test-client-id", type: "string", category: "google")
      insert_setting("google.oauth.redirect_uri", "http://localhost:4000/auth/google/callback", type: "string", category: "google")

      assert {:ok, url} = OAuth.generate_auth_url("12345")
      assert url =~ "accounts.google.com"
      assert url =~ "test-client-id"
    end
  end

  describe "connected?/0" do
    test "returns false when no refresh token" do
      refute OAuth.connected?()
    end
  end

  describe "disconnect/0" do
    test "returns :ok" do
      assert :ok = OAuth.disconnect()
    end
  end

  describe "add_scope/1" do
    test "accepts a scope string" do
      result = OAuth.add_scope("https://www.googleapis.com/auth/drive.readonly")
      assert result == :ok or is_atom(result)
    end
  end
end
