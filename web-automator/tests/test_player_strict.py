"""A step that cannot do its job fails the run (reports/WEB_AUTOMATOR_TARGET.md §2).

Only click, download and Playwright exceptions used to end a run with
status "error". fill, select and check logged a missing selector or an
exception and carried on, so a replay that silently skipped the password field
reported success. And check ignored its value: a recorded uncheck replayed as a
check.

Now: a fill, select or check whose selector matches nothing, or that raises,
ends the run with status "error" naming the step; check sets the state the
recipe asks for (`checked: true|false`) through set_checked; wait sleeps for
its `seconds`.
"""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.player import Player


@pytest.fixture
def page():
    page = AsyncMock()
    page.keyboard = AsyncMock()
    page.frames = [page]
    page.goto.return_value = MagicMock(headers={}, status=200)
    page.query_selector.return_value = None  # nothing matches, anywhere
    return page


def _play(steps):
    return Player(config={"url": "https://example.com", "steps": steps})


class TestMissingSelectorFailsTheRun:
    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "step",
        [
            {"action": "fill", "selector": "#password", "value": "x", "timeout_ms": 1000},
            {"action": "select", "selector": "select#account", "value": "main", "timeout_ms": 1000},
            {"action": "check", "selector": "#agree", "checked": True, "timeout_ms": 1000},
        ],
        ids=["fill", "select", "check"],
    )
    async def test_missing_selector(self, page, step):
        result = await _play([step]).run(page)

        assert result["status"] == "error"
        assert step["selector"] in result["error"]

    @pytest.mark.asyncio
    async def test_later_steps_do_not_run(self, page):
        result = await _play(
            [
                {"action": "fill", "selector": "#password", "value": "x", "timeout_ms": 1000},
                {"action": "navigate", "url": "https://example.com/next"},
            ]
        ).run(page)

        assert result["status"] == "error"
        # Only the recipe's own url was opened; the navigate step never ran.
        assert page.goto.await_count == 1


class TestAStepThatRaisesFailsTheRun:
    @pytest.mark.asyncio
    async def test_fill_raises(self, page):
        el = AsyncMock()
        el.is_visible.return_value = True
        el.fill.side_effect = Exception("element is not editable")
        el.type.side_effect = Exception("element is not editable")
        el.click.side_effect = Exception("element is not editable")
        page.query_selector.return_value = el

        result = await _play([{"action": "fill", "selector": "#user", "value": "alex"}]).run(page)

        assert result["status"] == "error"
        assert "#user" in result["error"]


class TestCheckSetsTheRequestedState:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("checked", [True, False])
    async def test_check_uses_set_checked(self, page, checked):
        el = AsyncMock()
        el.is_visible.return_value = True
        page.query_selector.return_value = el

        result = await _play([{"action": "check", "selector": "#box", "checked": checked}]).run(page)

        assert result["status"] == "success"
        el.set_checked.assert_awaited_once_with(checked)


class TestWait:
    @pytest.mark.asyncio
    async def test_wait_sleeps_for_its_seconds(self, page):
        with patch("app.player.asyncio.sleep", new=AsyncMock()) as sleep:
            result = await _play([{"action": "wait", "seconds": 1.5}]).run(page)

        assert result["status"] == "success"
        sleep.assert_any_await(1.5)
