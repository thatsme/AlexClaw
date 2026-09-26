defmodule AlexClaw.Auth.RecoveryCodesRngTest do
  @moduledoc """
  Recovery codes come from the operating system's cryptographic generator,
  not from `:rand` (S8 M16): `:rand` is predictable from its seed, so seeding
  it the same way twice must not give the same codes.
  """
  use AlexClaw.DataCase, async: false
  @moduletag :integration
  @moduletag :vault

  alias AlexClaw.Auth.RecoveryCodes

  test "the same :rand seed does not give the same codes" do
    :rand.seed(:exsss, {1, 2, 3})
    first = RecoveryCodes.generate()
    :rand.seed(:exsss, {1, 2, 3})
    second = RecoveryCodes.generate()

    assert MapSet.disjoint?(MapSet.new(first), MapSet.new(second))
  end

  test "every code is two groups of five from the alphabet" do
    for code <- RecoveryCodes.generate(),
        do: assert(code =~ ~r/\A[0-9ABCDEFGHJKMNPQRSTVWXYZ]{5}-[0-9ABCDEFGHJKMNPQRSTVWXYZ]{5}\z/)
  end
end
