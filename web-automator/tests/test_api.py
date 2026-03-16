"""Tests for the web-automator FastAPI endpoints.

Uses FastAPI's TestClient (sync httpx under the hood) —
no browser or Xvfb needed.
"""

import pytest
from unittest.mock import AsyncMock, patch, MagicMock

from fastapi.testclient import TestClient

from app.main import app, app_state, AppState, SessionState


@pytest.fixture(autouse=True)
def reset_state():
    """Reset app state before each test."""
    app_state.state = SessionState.idle
    app_state.session_id = None
    app_state.started_at = None
    app_state.recorder = None
    app_state.context = None
    app_state.page = None
    yield


@pytest.fixture
def client():
    return TestClient(app)


class TestHealth:
    def test_health(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ok"
        assert "version" in data


class TestStatus:
    def test_idle_status(self, client):
        resp = client.get("/status")
        assert resp.status_code == 200
        data = resp.json()
        assert data["state"] == "idle"
        assert data["session_id"] is None

    def test_recording_status(self, client):
        app_state.state = SessionState.recording
        app_state.session_id = "test-123"
        app_state.started_at = "2026-01-01T00:00:00"

        resp = client.get("/status")
        data = resp.json()
        assert data["state"] == "recording"
        assert data["session_id"] == "test-123"


class TestForceStop:
    def test_stop_when_idle(self, client):
        resp = client.post("/stop")
        assert resp.status_code == 200
        data = resp.json()
        assert data["message"] == "Already idle"

    def test_stop_when_recording(self, client):
        app_state.state = SessionState.recording
        app_state.session_id = "test-123"

        resp = client.post("/stop")
        assert resp.status_code == 200
        data = resp.json()
        assert "Stopped" in data["message"]
        assert app_state.state == SessionState.idle


class TestRecord:
    def test_record_rejects_when_not_idle(self, client):
        app_state.state = SessionState.recording

        resp = client.post("/record", json={"url": "https://example.com"})
        assert resp.status_code == 400

    def test_record_rejects_when_playing(self, client):
        app_state.state = SessionState.playing

        resp = client.post("/record", json={"url": "https://example.com"})
        assert resp.status_code == 400


class TestStopRecording:
    def test_stop_recording_when_not_recording(self, client):
        resp = client.post("/record/abc123/stop")
        assert resp.status_code == 400

    def test_stop_recording_wrong_session(self, client):
        app_state.state = SessionState.recording
        app_state.session_id = "real-session"

        resp = client.post("/record/wrong-session/stop")
        assert resp.status_code == 404


class TestPlay:
    def test_play_rejects_when_not_idle(self, client):
        app_state.state = SessionState.recording

        resp = client.post("/play", json={"config": {"url": "https://example.com"}})
        assert resp.status_code == 400
