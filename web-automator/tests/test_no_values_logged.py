"""Values are never logged (reports/WEB_AUTOMATOR_TARGET.md §1.4).

The player logged `Fill %s = %s`, `Select %s = %s` and `Check %s = %s` with the
value (player.py:121, :159, :177), and the recorder logged the first 50
characters of every input it saw — password fields included — while recording
(recorder.py:339, through the description the page's JavaScript builds). A
value typed into a site is the user's data and may be a password; the sidecar's
log is not a place for it.

Selectors and action names may still be logged: they are what makes a log
useful.
"""

import json
import logging

import pytest
from unittest.mock import AsyncMock, MagicMock

from app.player import Player
from app.recorder import Recorder

SECRET = "s3cr3t-value-7731"


@pytest.fixture
def all_logs(caplog):
    caplog.set_level(logging.DEBUG)
    return caplog


@pytest.fixture
def mock_page():
    page = AsyncMock()
    page.keyboard = AsyncMock()
    page.frames = [page]
    page.goto.return_value = MagicMock(headers={}, status=200)
    el = AsyncMock()
    el.is_visible.return_value = True
    el.is_checked.return_value = False
    el.evaluate.return_value = "SELECT"
    page.query_selector.return_value = el
    return page


class TestPlayer:
    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "step",
        [
            {"action": "fill", "selector": "#password", "value": SECRET},
            {"action": "select", "selector": "select[name='account']", "value": SECRET},
        ],
    )
    async def test_a_step_value_is_not_logged(self, all_logs, mock_page, step):
        player = Player(config={"url": "https://example.com", "steps": [step]})
        result = await player.run(mock_page)

        assert result["status"] == "success"
        assert SECRET not in all_logs.text
        assert step["selector"] in all_logs.text, "the selector should still be logged"

    @pytest.mark.asyncio
    async def test_a_failing_step_does_not_log_its_value(self, all_logs, mock_page):
        el = AsyncMock()
        el.click.side_effect = Exception(f"element detached while typing {SECRET}")
        mock_page.query_selector.return_value = el

        player = Player(
            config={
                "url": "https://example.com",
                "steps": [{"action": "fill", "selector": "#password", "value": SECRET}],
            }
        )
        await player.run(mock_page)

        assert SECRET not in all_logs.text


class TestRecorder:
    @pytest.mark.asyncio
    async def test_a_password_field_value_is_not_logged(self, all_logs):
        recorder = Recorder("s1", "https://portal.example.com")
        await recorder._on_dom_action(
            json.dumps(
                {
                    "action_type": "fill",
                    "selector": "#password",
                    "value": SECRET,
                    "input_type": "password",
                    "description": f"Fill #password = {SECRET[:50]}",
                }
            )
        )

        assert len(recorder.actions) == 1
        assert SECRET not in all_logs.text
        assert SECRET[:8] not in all_logs.text, "no prefix of the value either"

    @pytest.mark.asyncio
    async def test_any_field_value_is_not_logged(self, all_logs):
        recorder = Recorder("s1", "https://portal.example.com")
        await recorder._on_dom_action(
            json.dumps(
                {
                    "action_type": "fill",
                    "selector": "input[name='iban']",
                    "value": SECRET,
                    "description": f"Fill input[name='iban'] = {SECRET[:50]}",
                }
            )
        )

        assert SECRET not in all_logs.text
