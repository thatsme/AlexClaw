"""The browser gets F1 too (reports/WEB_AUTOMATOR_TARGET.md §1.2).

A recipe's navigations, and every request its pages make, leave from Chromium,
not through AlexClaw's HostGuard. So the player runs a small filtering forward
proxy (app.egress.EgressProxy) and forces Chromium through it. The proxy does
what HostGuard does: resolve the name, refuse if ANY address is internal or the
name does not resolve, and connect to the address it checked — one place, per
connection, so there is no second lookup to race.

`allow` is an exact set of "host:port" origins let through despite being
internal. The player gets none; the studio (phase 3) will get alexclaw-prod.
Here it admits one local test server so an allowed hop can happen offline.

Refusal is 403 for plain HTTP and a refused CONNECT (403) for HTTPS and
WebSockets over TLS.
"""

import asyncio
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
import pytest

from app.egress import EgressProxy, is_blocked_ip, check_host, Blocked
from app.browser import chromium_args, context_options


# ---------------------------------------------------------------- addresses


BLOCKED_IPS = [
    "127.0.0.1", "127.255.255.254", "0.0.0.0", "10.0.0.1", "172.16.0.1",
    "172.31.255.254", "192.168.1.1", "100.64.0.1", "169.254.169.254",
    "198.18.0.1", "224.0.0.1", "255.255.255.255",
    "::1", "::", "fc00::1", "fd12:3456::1", "fe80::1",
    "::ffff:127.0.0.1", "::ffff:10.0.0.1",
]

PUBLIC_IPS = ["1.1.1.1", "93.184.215.14", "2606:4700:4700::1111"]


@pytest.mark.parametrize("ip", BLOCKED_IPS)
def test_internal_addresses_are_blocked(ip):
    assert is_blocked_ip(ip)


@pytest.mark.parametrize("ip", PUBLIC_IPS)
def test_public_addresses_are_not(ip):
    assert not is_blocked_ip(ip)


@pytest.mark.parametrize(
    "host",
    ["localhost", "LOCALHOST", "127.0.0.1", "0x7f000001", "2130706433",
     "this-name-does-not-resolve.invalid"],
)
def test_check_host_refuses_internal_and_unresolvable(host):
    with pytest.raises(Blocked):
        check_host(host, 80, allow=frozenset())


def test_check_host_returns_the_address_to_connect_to_for_a_public_literal():
    assert check_host("1.1.1.1", 443, allow=frozenset()) == ["1.1.1.1"]


def test_allow_is_exact_host_and_port():
    assert check_host("127.0.0.1", 5001, allow=frozenset({"127.0.0.1:5001"}))
    with pytest.raises(Blocked):
        check_host("127.0.0.1", 5002, allow=frozenset({"127.0.0.1:5001"}))


# ---------------------------------------------------------------- the proxy


class _Target(BaseHTTPRequestHandler):
    """A local server that records every request that reaches it."""

    hits: list = []
    redirect_to: str = ""

    def do_GET(self):  # noqa: N802
        type(self).hits.append(self.path)
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", type(self).redirect_to)
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


def _serve(handler_cls):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


@pytest.fixture
def allowed_target():
    handler = type("Allowed", (_Target,), {"hits": []})
    server = _serve(handler)
    yield server, handler
    server.shutdown()


@pytest.fixture
def forbidden_target():
    handler = type("Forbidden", (_Target,), {"hits": []})
    server = _serve(handler)
    yield server, handler
    server.shutdown()


@pytest.fixture
def proxy_for():
    """Start an EgressProxy on its own event loop thread; yield a factory."""
    started = []

    def start(allow):
        loop = asyncio.new_event_loop()
        threading.Thread(target=loop.run_forever, daemon=True).start()
        proxy = EgressProxy(allow=frozenset(allow))
        port = asyncio.run_coroutine_threadsafe(proxy.start(), loop).result(5)
        started.append((proxy, loop))
        return f"http://127.0.0.1:{port}"

    yield start

    for proxy, loop in started:
        asyncio.run_coroutine_threadsafe(proxy.stop(), loop).result(5)
        loop.call_soon_threadsafe(loop.stop)


def test_an_allowed_origin_is_reached(proxy_for, allowed_target):
    server, handler = allowed_target
    origin = f"127.0.0.1:{server.server_port}"

    with httpx.Client(proxy=proxy_for({origin})) as client:
        resp = client.get(f"http://{origin}/ok")

    assert resp.status_code == 200
    assert handler.hits == ["/ok"]


def test_an_internal_origin_is_refused_and_never_reached(proxy_for, forbidden_target):
    server, handler = forbidden_target

    with httpx.Client(proxy=proxy_for(set())) as client:
        resp = client.get(f"http://127.0.0.1:{server.server_port}/ok")

    assert resp.status_code == 403
    assert resp.headers.get("x-alexclaw-egress") == "refused"
    assert handler.hits == []


def test_a_name_is_refused_like_its_address(proxy_for, forbidden_target):
    server, handler = forbidden_target

    with httpx.Client(proxy=proxy_for(set())) as client:
        resp = client.get(f"http://localhost:{server.server_port}/ok")

    assert resp.status_code == 403
    assert handler.hits == []


def test_a_redirect_to_an_internal_origin_is_refused_on_the_second_hop(
    proxy_for, allowed_target, forbidden_target
):
    allowed, allowed_handler = allowed_target
    forbidden, forbidden_handler = forbidden_target
    allowed_handler.redirect_to = f"http://127.0.0.1:{forbidden.server_port}/ok"
    origin = f"127.0.0.1:{allowed.server_port}"

    with httpx.Client(proxy=proxy_for({origin}), follow_redirects=True) as client:
        resp = client.get(f"http://{origin}/redirect")

    assert resp.status_code == 403
    assert allowed_handler.hits == ["/redirect"]
    assert forbidden_handler.hits == []


def test_connect_to_an_internal_origin_is_refused(proxy_for, forbidden_target):
    """HTTPS and wss go through CONNECT: the tunnel itself must be refused."""
    server, handler = forbidden_target

    with httpx.Client(proxy=proxy_for(set()), verify=False) as client:
        with pytest.raises(httpx.ProxyError):
            client.get(f"https://127.0.0.1:{server.server_port}/ok")

    assert handler.hits == []


def test_a_non_proxy_request_to_the_proxy_itself_is_refused(proxy_for):
    """The proxy is not a web server: a request for its own address is not
    served and not forwarded to itself."""
    url = proxy_for(set())

    resp = httpx.get(f"{url}/")

    assert resp.status_code in (400, 403)


# ---------------------------------------------------------------- Chromium


def test_chromium_is_forced_through_the_proxy():
    args = chromium_args(proxy_port=18080)

    assert "--proxy-server=http://127.0.0.1:18080" in args
    # Without this, Chromium sends loopback requests directly, bypassing the proxy.
    assert "--proxy-bypass-list=<-loopback>" in args
    # QUIC is UDP and does not go through an HTTP proxy.
    assert "--disable-quic" in args
    # WebRTC can open UDP to any address, including internal ones.
    assert "--force-webrtc-ip-handling-policy=disable_non_proxied_udp" in args


def test_service_workers_are_blocked():
    """A service worker can make requests the page's routing never sees."""
    assert context_options()["service_workers"] == "block"
