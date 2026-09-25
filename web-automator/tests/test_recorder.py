"""Tests for the Recorder class — action parsing and results.

The network-request classifiers (_is_interesting, _classify_action) and their
tests were removed in 0.4.0 S4b: dead code — recordings are built from the
page's DOM actions, and _classify_action put request bodies into action
descriptions.
"""

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
