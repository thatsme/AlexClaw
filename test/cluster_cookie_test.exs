defmodule AlexClaw.ClusterCookieTest do
  # System.put_env is global, so this module must not run beside another.
  use ExUnit.Case, async: false
  @moduletag :docs

  # The Erlang cookie is a remote shell. A node whose cookie is a value printed
  # in this repository will accept a connection from anyone who can reach its
  # distribution port, and run whatever they send, as the application.
  #
  # Two compose files shipped exactly that: `alexclaw_default` as a fallback in
  # docker-compose.yml, and `alexclaw_swarm` hardcoded twice in the swarm file,
  # where it was not overridable by environment at all. Both are public the
  # moment the repository is.
  #
  # This fails the build if a literal default comes back, or if the boot guard
  # stops rejecting the two that were published.

  @published ~w(alexclaw_default alexclaw_swarm)

  defp compose_files, do: Path.wildcard("docker-compose*.yml")

  test "no compose file supplies a cluster cookie value of its own" do
    offenders =
      for path <- compose_files(),
          {line, n} <- Enum.with_index(String.split(File.read!(path), "\n"), 1),
          String.contains?(line, "CLUSTER_COOKIE"),
          not required_from_environment?(line),
          do: "#{path}:#{n} #{String.trim(line)}"

    assert offenders == [],
           """
           A compose file carries a cluster cookie value:
             #{Enum.join(offenders, "\n  ")}

           The cookie has to come from the environment and have no fallback.
           `${CLUSTER_COOKIE:?...}` fails the `docker compose` invocation with
           its own message; `${CLUSTER_COOKIE:-something}` quietly hands every
           deployment the same secret.
           """
  end

  # The scan below looks for something that must not be there, so an empty
  # corpus passes it. The test image has to carry the compose files, and the
  # Dockerfile's test stage copies them for this reason alone.
  test "the compose files reach this test" do
    files = compose_files()

    assert files != [],
           "no docker-compose*.yml found — the scan below would pass by finding nothing"

    assert Enum.any?(files, &String.contains?(File.read!(&1), "CLUSTER_COOKIE")),
           "no compose file mentions CLUSTER_COOKIE, so either it stopped being passed " <>
             "to the container or the wrong files are being read"
  end

  # `${CLUSTER_COOKIE:?message}` and nothing else: `:-` supplies a default and
  # a bare `${CLUSTER_COOKIE}` accepts an empty one.
  #
  # The quotes are part of the check rather than tidiness. The message contains
  # a colon and an unquoted YAML scalar ends at the first `: `, which made both
  # compose files unparseable the first time this was written — `docker compose`
  # reported a syntax error on line 70 instead of a missing cookie, and the
  # guard it was reporting on never ran.
  defp required_from_environment?(line) do
    Regex.match?(~r/CLUSTER_COOKIE:\s*"\$\{CLUSTER_COOKIE:\?[^}]+\}"/, line)
  end

  # config/runtime.exs itself, evaluated the way a production boot evaluates
  # it, rather than grepped for the shape of a check. What matters is that the
  # boot stops, and only running the file says whether it does.
  describe "the boot guard" do
    test "refuses to boot without a cookie" do
      assert_raise RuntimeError, ~r/CLUSTER_COOKIE not set/, fn -> read_prod_config(nil) end
    end

    test "refuses the cookies that shipped as defaults" do
      for cookie <- @published do
        assert_raise RuntimeError, ~r/ships in this/, fn -> read_prod_config(cookie) end
      end
    end

    # The refusals are worth nothing unless the accepting case boots.
    test "accepts a generated one" do
      assert Keyword.has_key?(read_prod_config("Zm9vYmFyYmF6cXV4"), :alex_claw)
    end
  end

  defp read_prod_config(cookie) do
    original = System.get_env("CLUSTER_COOKIE")
    put_cookie(cookie)

    try do
      Config.Reader.read!("config/runtime.exs", env: :prod)
    after
      put_cookie(original)
    end
  end

  defp put_cookie(nil), do: System.delete_env("CLUSTER_COOKIE")
  defp put_cookie(value), do: System.put_env("CLUSTER_COOKIE", value)

  # Documented as required, and required in fact. The reverse direction —
  # documented but never read — is documentation_test's.
  test "the required variable is documented as one" do
    body = File.read!("docs/getting-started/configuration.md")
    required = body |> String.split("## Required Environment Variables", parts: 2) |> List.last()

    assert required =~ "`CLUSTER_COOKIE`",
           "CLUSTER_COOKIE stops a boot when it is missing, so it belongs in the table " <>
             "of variables that must be set before first boot"
  end
end
