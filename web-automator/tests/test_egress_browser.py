"""The browser's F1, end to end (reports/WEB_AUTOMATOR_TARGET.md §1.2).

test_egress.py proves the proxy and the Chromium flags separately. This proves
the wiring: a real /play, through the real middleware, the real per-play
EgressProxy and a real headless Chromium, cannot reach an internal address —
and says so, instead of reporting success on the proxy's empty 403 page.

A refused navigation fails the run. The proxy marks every refusal with the
response header `x-alexclaw-egress: refused`; a navigation (the recipe's `url`
or a `navigate` step) whose response carries it fails with an error naming
"egress". Sub-resources a page tries to load are simply refused.

Marked `browser`: it launches Chromium, so it takes seconds, not milliseconds.
It runs in `make test-python`.
"""

import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from tests.token_file import use_token

import pytest
from fastapi.testclient import TestClient

from app.main import app, app_state, SessionState

pytestmark = pytest.mark.browser

TOKEN = "test-automator-token"


class _Recorder(BaseHTTPRequestHandler):
    hits: list = []

    def do_GET(self):  # noqa: N802
        type(self).hits.append(self.path)
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b"<html><body>internal</body></html>")

    def log_message(self, *args):
        pass


@pytest.fixture
def internal_server():
    handler = type("Internal", (_Recorder,), {"hits": []})
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_port}", handler
    server.shutdown()


@pytest.fixture
def client(monkeypatch):
    use_token(monkeypatch, TOKEN)
    app_state.state = SessionState.idle
    return TestClient(app, headers={"Authorization": f"Bearer {TOKEN}"})


def play(client, config):
    resp = client.post(
        "/play",
        json={"play_id": "p-egress001", "deadline_ms": 60_000, "config": config},
        timeout=90,
    )
    # A refused play is a completed request with status "error": anything but
    # 200 means the request itself was wrong, and the test would prove nothing.
    assert resp.status_code == 200, resp.text
    return resp.json()


def test_the_recipe_url_cannot_reach_an_internal_address(client, internal_server):
    url, handler = internal_server

    result = play(client, {"url": f"{url}/secret", "steps": []})

    assert handler.hits == [], "the internal server was reached through /play"
    assert result["status"] == "error"
    assert "egress" in result["error"].lower()


def test_a_navigate_step_cannot_reach_an_internal_address(client, internal_server):
    """The recipe's first page must be a public http(s) page (the contract
    refuses about:blank), so this needs the internet. Without it the first
    navigation fails before the navigate step runs, and the test is skipped —
    it never passes by accident."""
    url, handler = internal_server

    result = play(
        client,
        {
            "url": "https://example.com/",
            "steps": [{"action": "navigate", "url": f"{url}/secret"}],
        },
    )

    assert handler.hits == []
    assert result["status"] == "error"
    if "egress" not in result["error"].lower() and "example.com" in result["error"]:
        pytest.skip(f"no internet for the first page: {result['error']}")
    assert "egress" in result["error"].lower()
    assert f"{url}/secret" in result["error"]


def test_an_https_url_to_an_internal_address_fails_at_the_tunnel(client, internal_server):
    """HTTPS goes through CONNECT; the proxy refuses the tunnel, and Chromium
    reports it as a tunnel failure. The run still fails naming egress."""
    url, handler = internal_server
    https_url = url.replace("http://", "https://")

    result = play(client, {"url": f"{https_url}/secret", "steps": []})

    assert handler.hits == []
    assert result["status"] == "error"
    assert "egress" in result["error"].lower()


def test_the_player_is_idle_again_after_a_refused_play(client, internal_server):
    url, _handler = internal_server

    play(client, {"url": f"{url}/secret", "steps": []})

    assert client.get("/status").json()["state"] == "idle"
