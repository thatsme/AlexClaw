"""Tests for the Recorder class — action parsing, classification, filtering."""

import json
import pytest
from unittest.mock import MagicMock, AsyncMock
from datetime import datetime

from app.recorder import Recorder, CapturedAction, DownloadedFile


@pytest.fixture
def recorder():
    return Recorder(
        session_id="test-session",
        base_url="https://example.com",
        output_dir="/tmp/test_recordings",
    )


class TestRecorderInit:
    def test_defaults(self, recorder):
        assert recorder.session_id == "test-session"
        assert recorder.base_url == "https://example.com"
        assert recorder.actions == []
        assert recorder.downloads == []
        assert recorder.request_count == 0
        assert recorder.ignored_count == 0

    def test_custom_patterns(self):
        r = Recorder("s1", "https://x.com", patterns=["custom", "pattern"])
        assert r.interesting_patterns == ["custom", "pattern"]


class TestIsInteresting:
    def _mock_request(self, url, method="GET", post_data=None, resource_type="xhr", headers=None):
        req = MagicMock()
        req.url = url
        req.method = method
        req.post_data = post_data
        req.resource_type = resource_type
        req.headers = headers or {}
        return req

    def test_ignores_static_assets(self, recorder):
        for ext in [".css", ".js", ".png", ".jpg", ".svg", ".woff2", ".ico"]:
            req = self._mock_request(f"https://example.com/asset{ext}")
            assert not recorder._is_interesting(req)

    def test_ignores_heartbeat_endpoints(self, recorder):
        for path in ["/pong", "/heartbeat", "/health", "/ping"]:
            req = self._mock_request(f"https://example.com{path}")
            assert not recorder._is_interesting(req)

    def test_post_with_interesting_pattern(self, recorder):
        req = self._mock_request(
            "https://example.com/api/download",
            method="POST",
            post_data="data"
        )
        assert recorder._is_interesting(req)

    def test_post_with_body_is_interesting(self, recorder):
        req = self._mock_request(
            "https://example.com/api/action",
            method="POST",
            post_data='{"key": "value"}'
        )
        assert recorder._is_interesting(req)

    def test_post_with_empty_body_ignored(self, recorder):
        req = self._mock_request(
            "https://example.com/api/noop",
            method="POST",
            post_data=""
        )
        assert not recorder._is_interesting(req)

    def test_get_api_path_is_interesting(self, recorder):
        req = self._mock_request("https://example.com/api/data")
        assert recorder._is_interesting(req)

    def test_get_v1_path_is_interesting(self, recorder):
        req = self._mock_request("https://example.com/v1/users")
        assert recorder._is_interesting(req)

    def test_document_is_interesting(self, recorder):
        req = self._mock_request(
            "https://example.com/page",
            resource_type="document"
        )
        assert recorder._is_interesting(req)

    def test_fetch_is_interesting(self, recorder):
        req = self._mock_request(
            "https://example.com/data",
            resource_type="fetch"
        )
        assert recorder._is_interesting(req)

    def test_random_get_ignored(self, recorder):
        req = self._mock_request(
            "https://example.com/something",
            resource_type="other"
        )
        assert not recorder._is_interesting(req)


class TestClassifyAction:
    def _mock_request(self, url, method="POST", post_data=None, resource_type="xhr", headers=None):
        req = MagicMock()
        req.url = url
        req.method = method
        req.post_data = post_data
        req.resource_type = resource_type
        req.headers = headers or {}
        return req

    def test_classifies_login(self, recorder):
        req = self._mock_request("https://example.com/auth/login", post_data="user=admin")
        action = recorder._classify_action(req)
        assert action.action_type == "login"

    def test_classifies_download(self, recorder):
        req = self._mock_request("https://example.com/api/export/excel")
        action = recorder._classify_action(req)
        assert action.action_type == "download_click"
        assert "excel" in action.description

    def test_classifies_filter(self, recorder):
        req = self._mock_request("https://example.com/api/search", post_data="q=test")
        action = recorder._classify_action(req)
        assert action.action_type == "filter"

    def test_classifies_navigation(self, recorder):
        req = self._mock_request(
            "https://example.com/page",
            method="GET",
            resource_type="document"
        )
        action = recorder._classify_action(req)
        assert action.action_type == "navigate"

    def test_classifies_form_submit(self, recorder):
        req = self._mock_request(
            "https://example.com/api/data",
            post_data='{"name": "test"}'
        )
        action = recorder._classify_action(req)
        assert action.action_type == "submit"

    def test_action_has_timestamp(self, recorder):
        req = self._mock_request("https://example.com/auth")
        action = recorder._classify_action(req)
        assert action.timestamp is not None


class TestDomActionCallback:
    @pytest.mark.asyncio
    async def test_on_dom_action_appends_fill(self, recorder):
        action_json = json.dumps({
            "timestamp": "2026-01-01T00:00:00Z",
            "action_type": "fill",
            "selector": "input[name=\"email\"]",
            "value": "test@example.com",
            "description": "Fill input[name=\"email\"] = test@example.com"
        })

        await recorder._on_dom_action(action_json)

        assert len(recorder.actions) == 1
        assert recorder.actions[0].action_type == "fill"
        assert recorder.actions[0].selector == 'input[name="email"]'
        assert recorder.actions[0].value == "test@example.com"

    @pytest.mark.asyncio
    async def test_on_dom_action_appends_click(self, recorder):
        action_json = json.dumps({
            "timestamp": "2026-01-01T00:00:00Z",
            "action_type": "click",
            "selector": "button",
            "value": "Submit",
            "description": "Click button"
        })

        await recorder._on_dom_action(action_json)

        assert len(recorder.actions) == 1
        assert recorder.actions[0].action_type == "click"

    @pytest.mark.asyncio
    async def test_on_dom_action_appends_check(self, recorder):
        action_json = json.dumps({
            "action_type": "check",
            "selector": 'input[name="topping"][value="cheese"]',
            "value": "cheese",
            "description": "Check cheese"
        })

        await recorder._on_dom_action(action_json)

        assert len(recorder.actions) == 1
        assert recorder.actions[0].action_type == "check"
        assert recorder.actions[0].value == "cheese"

    @pytest.mark.asyncio
    async def test_on_dom_action_appends_select(self, recorder):
        action_json = json.dumps({
            "action_type": "select",
            "selector": 'input[name="size"][value="medium"]',
            "value": "medium",
            "description": "Select medium"
        })

        await recorder._on_dom_action(action_json)

        assert len(recorder.actions) == 1
        assert recorder.actions[0].action_type == "select"

    @pytest.mark.asyncio
    async def test_on_dom_action_handles_invalid_json(self, recorder):
        await recorder._on_dom_action("not json")
        assert len(recorder.actions) == 0

    @pytest.mark.asyncio
    async def test_multiple_actions(self, recorder):
        for i in range(5):
            await recorder._on_dom_action(json.dumps({
                "action_type": "fill",
                "selector": f"input_{i}",
                "value": f"val_{i}",
                "description": f"Fill {i}"
            }))

        assert len(recorder.actions) == 5


class TestBuildResults:
    def test_empty_results(self, recorder):
        results = recorder._build_results()
        assert results["actions"] == []
        assert results["downloads"] == []
        assert results["summary"]["captured_actions"] == 0

    @pytest.mark.asyncio
    async def test_results_include_dom_actions(self, recorder):
        await recorder._on_dom_action(json.dumps({
            "action_type": "fill",
            "selector": "input",
            "value": "test",
            "description": "Fill input"
        }))

        results = recorder._build_results()
        assert len(results["actions"]) == 1
        assert results["summary"]["captured_actions"] == 1
        assert results["summary"]["action_summary"]["fill"] == 1

    def test_results_summary_structure(self, recorder):
        results = recorder._build_results()
        summary = results["summary"]
        assert "session_id" in summary
        assert "base_url" in summary
        assert "total_requests" in summary
        assert "ignored_requests" in summary
        assert "captured_actions" in summary
        assert "downloaded_files" in summary
        assert "action_summary" in summary
