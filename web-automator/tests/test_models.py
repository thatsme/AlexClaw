"""Tests for Pydantic models — validation, defaults, serialization."""

import pytest
from app.models import (
    RecordRequest, PlayRequest, PlayResponse, StatusResponse,
    HealthResponse, SessionState, CapturedAction, InteractStep,
)


class TestRecordRequest:
    def test_defaults(self):
        req = RecordRequest(url="https://example.com")
        assert req.url == "https://example.com"
        assert req.timeout == 300
        assert "download" in req.patterns

    def test_custom_patterns(self):
        req = RecordRequest(url="https://x.com", patterns=["a", "b"])
        assert req.patterns == ["a", "b"]


class TestPlayRequest:
    def test_config_required(self):
        req = PlayRequest(config={"url": "https://x.com", "steps": []})
        assert req.config["url"] == "https://x.com"


class TestPlayResponse:
    def test_success(self):
        resp = PlayResponse(status="success", output="Done")
        assert resp.status == "success"
        assert resp.downloads == []
        assert resp.screenshots == []
        assert resp.scraped_data == []

    def test_error(self):
        resp = PlayResponse(status="error", error="Timeout")
        assert resp.error == "Timeout"


class TestStatusResponse:
    def test_idle(self):
        resp = StatusResponse(state=SessionState.idle)
        assert resp.state == SessionState.idle
        assert resp.session_id is None

    def test_recording(self):
        resp = StatusResponse(state=SessionState.recording, session_id="abc")
        assert resp.session_id == "abc"


class TestHealthResponse:
    def test_defaults(self):
        resp = HealthResponse()
        assert resp.status == "ok"
        assert resp.version == "1.0.0"


class TestCapturedAction:
    def test_minimal(self):
        action = CapturedAction(
            timestamp="2026-01-01T00:00:00",
            action_type="click",
            description="Click button"
        )
        assert action.selector is None
        assert action.value is None

    def test_full(self):
        action = CapturedAction(
            timestamp="2026-01-01T00:00:00",
            action_type="fill",
            description="Fill email",
            selector="input[name='email']",
            value="test@test.com",
            url="https://example.com"
        )
        assert action.selector == "input[name='email']"


class TestInteractStep:
    def test_minimal(self):
        step = InteractStep(action="click")
        assert step.selector is None
        assert step.value is None

    def test_full(self):
        step = InteractStep(
            action="fill",
            selector="input",
            value="test",
            timeout=10
        )
        assert step.timeout == 10
