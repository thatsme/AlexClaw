defmodule AlexClaw.CheckOriginTest do
  # System.put_env is global, so this module must not run beside another.
  use ExUnit.Case, async: false
  @moduletag :docs

  @moduledoc """
  Which origins the LiveView socket will accept.

  Phoenix falls back to `url: [host: ...]` when `check_origin` is unset, which
  meant the endpoint accepted `localhost` and refused `127.0.0.1`. 0.3.28 bound
  the published port to `127.0.0.1`, so the address the compose file advertised
  was the one the socket turned away: the page rendered from the initial HTTP
  response and then sat there, every button inert, with one line in the log to
  say why.

  Asserted against `config/runtime.exs` evaluated the way a production boot
  evaluates it, rather than against a list copied into the test. An origin in
  the list is one the transport accepts; an origin outside it is one it
  rejects — that comparison is all `check_origin` does.
  """

  @loopback ["http://localhost:5001", "http://127.0.0.1:5001"]

  # runtime.exs refuses to produce a production configuration without a cluster
  # cookie, so one is supplied here. It is not what this test is about.
  defp origins(env) do
    env =
      env
      |> Map.put_new("CLUSTER_COOKIE", "Zm9vYmFyYmF6cXV4")
      |> Map.put_new("ADMIN_PORT", nil)

    original = Enum.map(env, fn {k, _v} -> {k, System.get_env(k)} end)
    Enum.each(env, fn {k, v} -> put(k, v) end)

    try do
      "config/runtime.exs"
      |> Config.Reader.read!(env: :prod)
      |> get_in([:alex_claw, AlexClawWeb.Endpoint, :check_origin])
    after
      Enum.each(original, fn {k, v} -> put(k, v) end)
    end
  end

  defp put(key, nil), do: System.delete_env(key)
  defp put(key, value), do: System.put_env(key, value)

  test "both loopback spellings are accepted by default" do
    accepted = origins(%{"CHECK_ORIGIN" => nil, "PHX_HOST" => nil})

    assert "http://127.0.0.1:5001" in accepted,
           "the address the compose file publishes is refused by the socket"

    assert "http://localhost:5001" in accepted
  end

  test "an origin outside the list is not accepted" do
    accepted = origins(%{"CHECK_ORIGIN" => nil, "PHX_HOST" => nil})

    refute "http://evil.example.com" in accepted
    refute "http://127.0.0.1:9999" in accepted, "a different port is a different origin"
  end

  test "PHX_HOST adds the public origin and keeps loopback" do
    accepted = origins(%{"CHECK_ORIGIN" => nil, "PHX_HOST" => "alexclaw.example.com"})

    assert "https://alexclaw.example.com" in accepted
    assert Enum.all?(@loopback, &(&1 in accepted)), "the host still answers to itself"
  end

  test "CHECK_ORIGIN replaces the list outright" do
    accepted =
      origins(%{
        "CHECK_ORIGIN" => "https://one.example.com, https://two.example.com",
        "PHX_HOST" => "ignored.example.com"
      })

    assert accepted == ["https://one.example.com", "https://two.example.com"]

    refute "http://127.0.0.1:5001" in accepted,
           "an explicit list is the whole list, or it is not explicit"
  end

  # ADMIN_PORT moves the published port; the origin the browser sends moves
  # with it. With the list fixed at :5001, every button on a :5002 install
  # did nothing.
  test "ADMIN_PORT=5002 is accepted on both loopback spellings, and :5001 no longer is" do
    accepted = origins(%{"ADMIN_PORT" => "5002", "CHECK_ORIGIN" => nil, "PHX_HOST" => nil})

    assert "http://127.0.0.1:5002" in accepted
    assert "http://localhost:5002" in accepted
    refute "http://127.0.0.1:5001" in accepted
  end

  test "ADMIN_PORT keeps PHX_HOST's origin and yields to CHECK_ORIGIN" do
    with_host =
      origins(%{
        "ADMIN_PORT" => "5002",
        "CHECK_ORIGIN" => nil,
        "PHX_HOST" => "alexclaw.example.com"
      })

    assert "https://alexclaw.example.com" in with_host

    explicit = origins(%{"ADMIN_PORT" => "5002", "CHECK_ORIGIN" => "https://one.example.com"})
    assert explicit == ["https://one.example.com"]
  end

  test "an ADMIN_PORT that is not a port stops the boot" do
    for bad <- ["", "abc", "0", "-1", "65536", "5002x"] do
      assert_raise RuntimeError, ~r/ADMIN_PORT/, fn ->
        origins(%{"ADMIN_PORT" => bad, "CHECK_ORIGIN" => nil})
      end
    end
  end

  test "blank entries and stray whitespace are dropped, not accepted" do
    accepted = origins(%{"CHECK_ORIGIN" => " https://one.example.com , , ", "PHX_HOST" => nil})

    assert accepted == ["https://one.example.com"]
  end
end
