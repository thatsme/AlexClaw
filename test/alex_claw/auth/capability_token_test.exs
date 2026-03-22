defmodule AlexClaw.Auth.CapabilityTokenTest do
  use ExUnit.Case, async: true

  alias AlexClaw.Auth.CapabilityToken

  describe "mint/2" do
    test "creates a valid token with given permissions" do
      token = CapabilityToken.mint([:web_read, :llm])
      assert {:ok, perms} = CapabilityToken.verify(token)
      assert MapSet.member?(perms, :web_read)
      assert MapSet.member?(perms, :llm)
    end

    test "token has correct permissions" do
      token = CapabilityToken.mint([:web_read])
      assert CapabilityToken.has_permission?(token, :web_read)
      refute CapabilityToken.has_permission?(token, :memory_write)
    end
  end

  describe "attenuate/3" do
    test "restricts permissions to intersection" do
      token = CapabilityToken.mint([:web_read, :llm, :memory_read])
      {:ok, attenuated} = CapabilityToken.attenuate(token, [:web_read, :memory_read])

      assert CapabilityToken.has_permission?(attenuated, :web_read)
      assert CapabilityToken.has_permission?(attenuated, :memory_read)
      refute CapabilityToken.has_permission?(attenuated, :llm)
    end

    test "attenuating to empty set yields no permissions" do
      token = CapabilityToken.mint([:web_read, :llm])
      {:ok, attenuated} = CapabilityToken.attenuate(token, [:memory_write])

      refute CapabilityToken.has_permission?(attenuated, :web_read)
      refute CapabilityToken.has_permission?(attenuated, :llm)
      refute CapabilityToken.has_permission?(attenuated, :memory_write)
    end

    test "double attenuation further restricts" do
      token = CapabilityToken.mint([:web_read, :llm, :memory_read])
      {:ok, a1} = CapabilityToken.attenuate(token, [:web_read, :llm])
      {:ok, a2} = CapabilityToken.attenuate(a1, [:web_read])

      assert CapabilityToken.has_permission?(a2, :web_read)
      refute CapabilityToken.has_permission?(a2, :llm)
    end
  end

  describe "verify/1" do
    test "valid token passes verification" do
      token = CapabilityToken.mint([:web_read])
      assert {:ok, _perms} = CapabilityToken.verify(token)
    end

    test "tampered token is rejected" do
      token = CapabilityToken.mint([:web_read])

      tampered = %{token | permissions: MapSet.new([:web_read, :memory_write])}
      assert {:error, :invalid_token} = CapabilityToken.verify(tampered)
    end

    test "tampered signature is rejected" do
      token = CapabilityToken.mint([:web_read])
      tampered = %{token | signature: "bogus_signature"}
      assert {:error, :invalid_token} = CapabilityToken.verify(tampered)
    end
  end

  describe "caveats" do
    test "expired token is rejected" do
      expired = DateTime.add(DateTime.utc_now(), -60, :second)
      token = CapabilityToken.mint([:web_read], expires_at: expired)
      assert {:error, :token_expired} = CapabilityToken.verify(token)
    end

    test "future expiry is allowed" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      token = CapabilityToken.mint([:web_read], expires_at: future)
      assert {:ok, _perms} = CapabilityToken.verify(token)
    end

    test "max_depth caveat enforced" do
      Process.put(:auth_chain_depth, 5)
      token = CapabilityToken.mint([:web_read], max_depth: 3)
      assert {:error, :max_depth_exceeded} = CapabilityToken.verify(token)
    after
      Process.delete(:auth_chain_depth)
    end

    test "max_depth caveat passes when within limit" do
      Process.put(:auth_chain_depth, 2)
      token = CapabilityToken.mint([:web_read], max_depth: 3)
      assert {:ok, _perms} = CapabilityToken.verify(token)
    after
      Process.delete(:auth_chain_depth)
    end
  end
end
