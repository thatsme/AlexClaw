"""Lifecycle (reports/WEB_AUTOMATOR_TARGET.md §3).

A play had no overall deadline, nothing cancelled it when AlexClaw gave up, and
all plays shared one browser singleton: a timed-out step left the sidecar
"playing" for minutes, and a stopped play's late cleanup could close the next
play's browser.

Now:
- /play takes a `play_id` (from AlexClaw) and a `deadline_ms`
  (1000..600000), both required, outside the recipe;
- the whole run is bounded by the deadline: past it the play ends with
  status "timeout", its browser closed, the sidecar idle;
- a client that disconnects cancels its play the same way;
- POST /play/{play_id}/stop stops that play and only that one (404 for any
  other id);
- each play opens its own browser session (app.main.open_play_session) and
  closes only that one; /status reports the running play's id, and a stopped
  play's cleanup never touches the next play.

These run a real uvicorn server in a thread, because a disconnect cannot be
simulated through TestClient. The browser is a fake session whose page.goto
sleeps, so a "slow page" costs nothing.
"""

import asyncio
import socket
import threading
import time
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest
import uvicorn

from app.main import app, app_state, SessionState

TOKEN = "test-automator-token"
HEADERS = {"Authorization": f"Bearer {TOKEN}"}
RECIPE = {"url": "https://example.com", "steps": []}


class FakeSession:
    """What open_play_session returns: a page and an async close()."""

    def __init__(self, goto_seconds):
        self.closed = False
        self.page = AsyncMock()
        self.page.keyboard = AsyncMock()
        self.page.frames = [self.page]

        async def goto(*_args, **_kwargs):
            await asyncio.sleep(goto_seconds)
            return MagicMock(headers={}, status=200)

        self.page.goto.side_effect = goto

    async def close(self):
        self.closed = True


@pytest.fixture
def sessions():
    """Each play gets the next delay from `delays`; every session is kept."""
    opened = []
    delays = []

    async def open_play_session(*_args, **_kwargs):
        session = FakeSession(delays.pop(0) if delays else 0)
        opened.append(session)
        return session

    with patch("app.main.open_play_session", new=open_play_session):
        yield opened, delays


@pytest.fixture
def server(monkeypatch, sessions):
    monkeypatch.setenv("WEB_AUTOMATOR_TOKEN", TOKEN)
    app_state.state = SessionState.idle

    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]

    srv = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    thread = threading.Thread(target=srv.run, daemon=True)
    thread.start()
    for _ in range(100):
        if srv.started:
            break
        time.sleep(0.05)

    yield f"http://127.0.0.1:{port}"

    srv.should_exit = True
    thread.join(5)
    app_state.state = SessionState.idle


def _eventually(check, seconds=5.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if check():
            return True
        time.sleep(0.05)
    return False


def _status(base):
    return httpx.get(f"{base}/status", headers=HEADERS).json()


def _play_in_background(base, play_id, deadline_ms=60_000):
    result = {}

    def run():
        resp = httpx.post(
            f"{base}/play",
            json={"play_id": play_id, "deadline_ms": deadline_ms, "config": RECIPE},
            headers=HEADERS,
            timeout=120,
        )
        result["status_code"] = resp.status_code
        result["body"] = resp.json()

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread, result


class TestTheRequest:
    @pytest.mark.parametrize(
        "body",
        [
            {"config": RECIPE, "deadline_ms": 5000},  # no play_id
            {"config": RECIPE, "play_id": "p-00000001"},  # no deadline_ms
            {"config": RECIPE, "play_id": "p-00000001", "deadline_ms": 999},
            {"config": RECIPE, "play_id": "p-00000001", "deadline_ms": 600_001},
            {"config": RECIPE, "play_id": "../../etc", "deadline_ms": 5000},
            {"config": RECIPE, "play_id": "short", "deadline_ms": 5000},
        ],
    )
    def test_play_id_and_deadline_are_required_and_bounded(self, server, sessions, body):
        opened, _ = sessions
        resp = httpx.post(f"{server}/play", json=body, headers=HEADERS)
        assert resp.status_code == 422
        assert opened == []


class TestDeadline:
    def test_the_deadline_ends_the_play(self, server, sessions):
        opened, delays = sessions
        delays.append(30)  # a page that would take 30 s

        started = time.monotonic()
        resp = httpx.post(
            f"{server}/play",
            json={"play_id": "p-deadline1", "deadline_ms": 1000, "config": RECIPE},
            headers=HEADERS,
            timeout=20,
        )
        elapsed = time.monotonic() - started

        assert resp.status_code == 200
        assert resp.json()["status"] == "timeout"
        assert elapsed < 5, f"took {elapsed:.1f}s for a 1 s deadline"
        assert opened[0].closed
        assert _status(server)["state"] == "idle"


class TestDisconnect:
    def test_a_client_that_goes_away_cancels_its_play(self, server, sessions):
        opened, delays = sessions
        delays.append(30)

        with pytest.raises(httpx.ReadTimeout):
            httpx.post(
                f"{server}/play",
                json={"play_id": "p-gone0001", "deadline_ms": 60_000, "config": RECIPE},
                headers=HEADERS,
                timeout=1,
            )

        assert _eventually(lambda: _status(server)["state"] == "idle"), "still playing after the client left"
        assert opened[0].closed


class TestStopById:
    def test_stop_takes_the_play_id(self, server, sessions):
        opened, delays = sessions
        delays.append(30)
        thread, result = _play_in_background(server, "p-stopme01")
        assert _eventually(lambda: _status(server)["state"] == "playing")

        wrong = httpx.post(f"{server}/play/p-someone1/stop", headers=HEADERS)
        assert wrong.status_code == 404
        assert _status(server)["state"] == "playing"

        right = httpx.post(f"{server}/play/p-stopme01/stop", headers=HEADERS)
        assert right.status_code == 200

        thread.join(10)
        assert result["body"]["status"] == "stopped"
        assert opened[0].closed
        assert _status(server)["state"] == "idle"


class TestOneBrowserPerPlay:
    def test_a_stopped_play_never_touches_the_next_one(self, server, sessions):
        opened, delays = sessions
        delays.extend([30, 3])  # the first play hangs; the second takes 3 s

        first, _ = _play_in_background(server, "p-first001")
        assert _eventually(lambda: _status(server)["state"] == "playing")
        httpx.post(f"{server}/play/p-first001/stop", headers=HEADERS)
        assert _eventually(lambda: _status(server)["state"] == "idle")

        second, result = _play_in_background(server, "p-second01")
        assert _eventually(lambda: _status(server).get("play_id") == "p-second01")

        first.join(10)  # the first play's cleanup has run by now
        time.sleep(0.5)

        status = _status(server)
        assert status["state"] == "playing", "the first play's cleanup reset the second play's state"
        assert status["play_id"] == "p-second01"
        assert not opened[1].closed, "the first play's cleanup closed the second play's browser"

        second.join(10)
        assert result["body"]["status"] == "success"
        assert opened[1].closed
        assert len(opened) == 2
