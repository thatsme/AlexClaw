"""F2 (reports/WEB_AUTOMATOR_TARGET.md §1.3): every route except /health
requires the shared token.

The sidecar's API had no authentication at all: anything on its network could
start a play, including one that runs JavaScript or writes files. The token
comes from the file named by WEB_AUTOMATOR_TOKEN_FILE (0.4.0), read at request time, and is
compared in constant time. Without a configured token the sidecar refuses every
protected route (503) — it never falls back to open.

The interactive API docs are not served: they describe every route and its
parameters to anyone who asks.
"""

import pytest
from fastapi.testclient import TestClient
from tests.token_file import use_token

from app.main import app, app_state, SessionState

TOKEN = "test-automator-token"

PROTECTED = [
    ("GET", "/status", None),
    ("POST", "/stop", None),
    ("POST", "/record", {"url": "https://example.com"}),
    ("POST", "/record/abc12345/stop", None),
    ("POST", "/play", {"config": {"url": "https://example.com", "steps": []}}),
    # Added with per-play stop (test_lifecycle.py); the auth middleware was
    # rewritten as plain ASGI in the same change, so every route is re-pinned.
    ("POST", "/play/p-00000001/stop", None),
]


@pytest.fixture(autouse=True)
def idle_state():
    app_state.state = SessionState.idle
    app_state.session_id = None
    yield


@pytest.fixture
def client(monkeypatch):
    use_token(monkeypatch, TOKEN)
    return TestClient(app)


def call(client, method, path, body, headers=None):
    return client.request(method, path, json=body, headers=headers or {})


class TestHealthIsOpen:
    def test_health_needs_no_token(self, client):
        assert client.get("/health").status_code == 200

    def test_health_works_without_a_configured_token(self, monkeypatch):
        monkeypatch.delenv("WEB_AUTOMATOR_TOKEN_FILE", raising=False)
        assert TestClient(app).get("/health").status_code == 200


class TestProtectedRoutes:
    @pytest.mark.parametrize("method,path,body", PROTECTED)
    def test_no_header_is_refused(self, client, method, path, body):
        assert call(client, method, path, body).status_code == 401

    @pytest.mark.parametrize("method,path,body", PROTECTED)
    def test_wrong_token_is_refused(self, client, method, path, body):
        resp = call(client, method, path, body, {"Authorization": "Bearer not-the-token"})
        assert resp.status_code == 401

    @pytest.mark.parametrize(
        "header",
        [
            TOKEN,  # no scheme
            f"Basic {TOKEN}",
            f"Bearer {TOKEN}x",
            f"Bearer {TOKEN[:-1]}",
            "Bearer ",
        ],
    )
    def test_malformed_header_is_refused(self, client, header):
        resp = client.get("/status", headers={"Authorization": header})
        assert resp.status_code == 401

    def test_the_right_token_reaches_the_route(self, client):
        resp = client.get("/status", headers={"Authorization": f"Bearer {TOKEN}"})
        assert resp.status_code == 200
        assert resp.json()["state"] == "idle"


class TestFailClosed:
    @pytest.mark.parametrize("method,path,body", PROTECTED)
    def test_no_configured_token_refuses_everything(self, monkeypatch, method, path, body):
        monkeypatch.delenv("WEB_AUTOMATOR_TOKEN_FILE", raising=False)
        resp = call(TestClient(app), method, path, body, {"Authorization": "Bearer anything"})
        assert resp.status_code == 503

    @pytest.mark.parametrize("method,path,body", PROTECTED)
    def test_an_empty_configured_token_refuses_everything(self, monkeypatch, method, path, body):
        use_token(monkeypatch, "")
        resp = call(TestClient(app), method, path, body, {"Authorization": "Bearer "})
        assert resp.status_code == 503


class TestEveryRouteIsCovered:
    """The list above is written by hand; this one is read from the app. A
    route added later without passing through the token check fails here,
    whatever its name."""

    def test_every_route_but_health_needs_the_token(self, client):
        import re
        from starlette.routing import Route

        open_routes = []
        for route in app.routes:
            if not isinstance(route, Route) or route.path == "/health":
                continue
            path = re.sub(r"\{[^}]+\}", "p-00000001", route.path)
            for method in sorted(route.methods or []):
                if method in ("HEAD", "OPTIONS"):
                    continue
                resp = client.request(method, path)
                if resp.status_code != 401:
                    open_routes.append(f"{method} {route.path} -> {resp.status_code}")

        assert open_routes == []


class TestDocsNotServed:
    @pytest.mark.parametrize("path", ["/docs", "/redoc", "/openapi.json"])
    def test_docs_are_not_served(self, client, path):
        resp = client.get(path, headers={"Authorization": f"Bearer {TOKEN}"})
        assert resp.status_code == 404
