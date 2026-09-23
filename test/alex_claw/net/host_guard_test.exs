defmodule AlexClaw.Net.HostGuardTest do
  @moduledoc """
  F1 (web-automator feasibility report): what a skill's HTTP may reach.

  SkillAPI.http_* checked only the :web_read permission, and :web_read is in the
  set that loads without a second factor. So a skill — one Forge wrote and
  loaded on its own — could POST to the web-automator's unauthenticated /play,
  or reach Postgres, the admin UI, the host and the cloud metadata address.

  The guard is the Req ADAPTER, not a request step. Req 0.5 does not re-run
  request steps on a redirect (steps.ex:1983 → run_request with no steps left),
  but it calls the adapter for every hop. So the adapter resolves, checks and
  connects to the address it checked, once per hop: redirects are guarded
  without re-implementing Req's redirect logic, there is no second lookup for
  DNS rebinding to exploit, and no Finch pool is created per hostname.

  A name that does not resolve is refused (fail closed), and a name is refused
  if ANY address it resolves to is.
  """
  use ExUnit.Case, async: true

  alias AlexClaw.Net.HostGuard

  describe "check_url/1 refuses internal destinations" do
    for url <- [
          # loopback and "this host", in every spelling
          "http://127.0.0.1/",
          "http://127.1/",
          "http://127.255.255.254:6900/",
          "http://0/",
          "http://0.0.0.0:6900/",
          "http://2130706433/",
          "http://0x7f000001/",
          "http://0x7f.1/",
          "http://017700000001/",
          "http://localhost/",
          "http://LOCALHOST:5001/",
          "http://localhost.:5001/",
          # private, shared, link-local (cloud metadata), benchmark, multicast, broadcast
          "http://10.0.0.1/",
          "http://172.16.0.1/",
          "http://172.31.255.254/",
          "http://192.168.1.1/",
          "http://100.64.0.1/",
          "http://169.254.169.254/latest/meta-data/",
          "http://198.18.0.1/",
          "http://224.0.0.1/",
          "http://255.255.255.255/",
          # IPv6, including IPv4-mapped
          "http://[::1]/",
          "http://[::]/",
          "http://[fc00::1]/",
          "http://[fd12:3456::1]/",
          "http://[fe80::1]/",
          "http://[::ffff:127.0.0.1]/",
          "http://[::ffff:10.0.0.1]/",
          # userinfo does not change the host
          "http://example.com@127.0.0.1/",
          # a name that does not resolve is refused, not let through
          "http://this-name-does-not-resolve.invalid/"
        ] do
      test "#{url}" do
        assert {:error, :blocked_host} = HostGuard.check_url(unquote(url))
      end
    end
  end

  describe "check_url/1 refuses what is not http(s)" do
    for url <- [
          "file:///etc/passwd",
          "ftp://1.1.1.1/",
          "gopher://1.1.1.1/",
          "//1.1.1.1/",
          "1.1.1.1",
          ""
        ] do
      test "#{inspect(url)}" do
        assert {:error, :invalid_url} = HostGuard.check_url(unquote(url))
      end
    end
  end

  # Literal public addresses: no DNS needed, so these run offline.
  describe "check_url/1 allows public addresses" do
    for url <- [
          "https://1.1.1.1/",
          "http://93.184.215.14:8080/x?y=1",
          "https://[2606:4700:4700::1111]/"
        ] do
      test "#{url}" do
        assert :ok = HostGuard.check_url(unquote(url))
      end
    end
  end

  # attach(req, allow: ["host:port", ...]) lets named origins through the guard.
  # Here it admits one local Bypass so a first hop can happen offline; every
  # other Bypass below is NOT allowed and has nothing stubbed, so a request that
  # reaches it fails the test when Bypass exits. The allow-list is exact
  # host:port, and it is the same mechanism a control-plane setting can feed
  # later — not a test-only seam.
  describe "attach/2: the guarded adapter" do
    setup do
      allowed = Bypass.open()
      forbidden = Bypass.open()

      %{
        allowed: allowed,
        origin: "127.0.0.1:#{allowed.port}",
        forbidden_url: "http://127.0.0.1:#{forbidden.port}/play"
      }
    end

    test "an internal URL is refused and never connected to", %{forbidden_url: url} do
      req = Req.new(url: url, retry: false) |> HostGuard.attach()
      assert {:error, %HostGuard.BlockedError{}} = Req.request(req)
    end

    test "a redirect to a refused origin is stopped on the second hop",
         %{allowed: allowed, origin: origin, forbidden_url: forbidden_url} do
      Bypass.expect_once(allowed, "GET", "/start", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", forbidden_url)
        |> Plug.Conn.resp(302, "")
      end)

      req =
        Req.new(url: "http://#{origin}/start", retry: false)
        |> HostGuard.attach(allow: [origin])

      assert {:error, %HostGuard.BlockedError{}} = Req.request(req)
    end

    test "a redirect within the allowed origin is followed",
         %{allowed: allowed, origin: origin} do
      Bypass.expect_once(allowed, "GET", "/start", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/done")
        |> Plug.Conn.resp(302, "")
      end)

      Bypass.expect_once(allowed, "GET", "/done", fn conn ->
        Plug.Conn.resp(conn, 200, "done")
      end)

      req =
        Req.new(url: "http://#{origin}/start", retry: false)
        |> HostGuard.attach(allow: [origin])

      assert {:ok, %{status: 200, body: "done"}} = Req.request(req)
    end

    test "allow is exact host:port — the same address on another port is refused",
         %{origin: origin, forbidden_url: url} do
      req = Req.new(url: url, retry: false) |> HostGuard.attach(allow: [origin])
      assert {:error, %HostGuard.BlockedError{}} = Req.request(req)
    end

    # A request that arrives with its own plug or adapter would run without the
    # guarded adapter; attach/2 must not silently accept or override it.
    test "attach/2 refuses a request that already carries its own adapter or plug" do
      for opts <- [[plug: fn conn -> conn end], [adapter: &Function.identity/1]] do
        req = Req.new([url: "https://1.1.1.1/"] ++ opts)
        assert_raise ArgumentError, fn -> HostGuard.attach(req) end
      end
    end
  end
end
