defmodule AlexClaw.OpenBaoPolicyTest do
  @moduledoc """
  AlexClaw's OpenBao token can do what AlexClaw does, and no more (S8 M2;
  THREAT_MODEL P7). The policy is written once, when OpenBao is initialised
  (`openbao/init.sh`), which the test stack runs for every suite.

  - No transit encrypt or decrypt: since 0.4.0 nothing is encrypted by
    AlexClaw, and a token that can decrypt is a decryption service for
    whoever holds it. HMAC and verify stay (the MCP key, recovery codes).
  - No `default` policy on the token: only what `alexclaw` grants.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @init File.read!("openbao/init.sh")

  test "grants no transit encrypt or decrypt" do
    refute @init =~ ~r{path "transit/encrypt}
    refute @init =~ ~r{path "transit/decrypt}
    assert @init =~ ~r{path "transit/hmac/alexclaw"}
    assert @init =~ ~r{path "transit/verify/alexclaw"}
  end

  test "the token may renew itself: the one path the default policy gave it" do
    assert @init =~ ~r{path "auth/token/renew-self" \{\s*capabilities = \["update"\]\s*\}}
  end

  test "the AppRole's tokens carry no default policy" do
    assert @init =~
             ~r{auth/approle/role/alexclaw[^\n]*\\\n(?:[^\n]*\\\n)*[^\n]*token_no_default_policy=true}
  end
end
