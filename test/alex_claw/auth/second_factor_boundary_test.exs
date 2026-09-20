defmodule AlexClaw.Auth.SecondFactorBoundaryTest do
  @moduledoc """
  The rest of the system asks for a second factor, not for TOTP.

  A behaviour with one implementation is only a seam if nothing reaches around
  it. This reads `lib/` and fails when a module that is not the implementation
  or a setup screen names `AlexClaw.Auth.TOTP` — because the day a second
  implementation arrives, every one of those would be a place that silently
  kept asking the old one.
  """
  use ExUnit.Case, async: true
  @moduletag :docs

  alias AlexClaw.Auth.SecondFactor

  # The implementation itself, and the two screens whose job is configuring
  # this particular factor: enrolling an authenticator is TOTP-specific work,
  # and pretending otherwise would be a worse abstraction than none.
  @allowed [
    "lib/alex_claw/auth/totp.ex",
    "lib/alex_claw/auth/second_factor/totp.ex",
    "lib/alex_claw_web/live/admin_live/services.ex",
    "lib/alex_claw/dispatcher/auth_commands.ex"
  ]

  defp sources, do: Path.wildcard("lib/**/*.ex")

  # A reference is an alias of the module or a call into it. A mention inside a
  # comment or a docstring is prose, and prose is allowed to explain.
  defp references_totp?(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&comment?/1)
    |> Enum.any?(&mentions_totp?/1)
  end

  defp comment?(line), do: String.trim_leading(line) |> String.starts_with?("#")

  defp mentions_totp?(line) do
    Regex.match?(~r/\bAlexClaw\.Auth\.TOTP\b/, line) or
      Regex.match?(~r/(?<![\w.])TOTP\.\w/, line)
  end

  test "nothing outside the implementation and the setup screens names TOTP" do
    offenders =
      for path <- sources(),
          path not in @allowed,
          references_totp?(File.read!(path)),
          do: path

    assert offenders == [],
           """
           These modules reach past AlexClaw.Auth.SecondFactor to the TOTP
           implementation:

             #{Enum.join(offenders, "\n  ")}

           Ask the behaviour instead — SecondFactor.impl().verify/2 or
           configured?/0 — or, if the code really is about enrolling an
           authenticator rather than about having a second factor, add it to
           @allowed here with the reason.
           """
  end

  test "the allow-list has not gone stale" do
    for path <- @allowed do
      assert File.exists?(path), "#{path} is allow-listed and does not exist"

      assert references_totp?(File.read!(path)),
             "#{path} no longer names TOTP — drop it from @allowed"
    end
  end

  # The seam is only real if the implementation is reachable by configuration.
  test "the implementation is selected through config, not hardcoded" do
    assert SecondFactor.impl() == SecondFactor.Totp

    Application.put_env(:alex_claw, :second_factor, __MODULE__.Stub)
    assert SecondFactor.impl() == __MODULE__.Stub
  after
    Application.delete_env(:alex_claw, :second_factor)
  end

  defmodule Stub do
    @moduledoc false
    @behaviour AlexClaw.Auth.SecondFactor

    @impl true
    def verify(_secret, _method), do: {:error, :invalid_code}

    @impl true
    def configured?, do: false

    @impl true
    def name, do: :stub
  end
end
