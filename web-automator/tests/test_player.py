"""Tests for the Player class — action execution logic.

Tests the action handlers without a real browser by mocking the Page object.
Steps use the recipe contract's shapes (tests/contract/recipes.json); the
strict-failure rules are in test_player_strict.py.
"""

import pytest
from unittest.mock import AsyncMock, MagicMock
from datetime import datetime

from app.player import Player


@pytest.fixture
def player():
    return Player(config={
        "url": "https://example.com",
        "steps": [],
    })


@pytest.fixture
def mock_page():
    page = AsyncMock()
    page.keyboard = AsyncMock()
    page.frames = [page]  # main frame only
    # A navigation's response is inspected synchronously (headers) for the
    # egress refusal marker; an AsyncMock there yields un-awaited coroutines.
    page.goto.return_value = MagicMock(headers={}, status=200)
    return page


def _element(**returns):
    el = AsyncMock()
    el.is_visible.return_value = True
    for name, value in returns.items():
        getattr(el, name).return_value = value
    return el


async def _run(page, steps):
    return await Player(config={"url": "https://example.com", "steps": steps}).run(page)


class TestPlayerInit:
    def test_defaults(self, player):
        assert player.downloads == []
        assert player.screenshots == []
        assert player.scraped_data == []

    def test_output_dir_is_not_taken_from_the_recipe(self):
        # output_dir is not in the contract: a recipe cannot choose where files go.
        p = Player(config={"url": "https://example.com", "steps": [], "output_dir": "/tmp/custom"})
        assert p.output_dir != "/tmp/custom"


class TestNavigate:
    @pytest.mark.asyncio
    async def test_navigate(self, player, mock_page):
        await player._navigate(mock_page, "https://example.com/page")
        mock_page.goto.assert_called_once_with(
            "https://example.com/page", wait_until="domcontentloaded"
        )


class TestFill:
    @pytest.mark.asyncio
    async def test_fill_text_field_types_the_value(self, mock_page):
        el = _element()
        mock_page.query_selector.return_value = el

        result = await _run(mock_page, [{"action": "fill", "selector": "input[name='email']", "value": "test@test.com"}])

        assert result["status"] == "success"
        typed = [c.args[0] for c in mock_page.keyboard.type.call_args_list if c.args]
        filled = [c.args[0] for c in el.fill.call_args_list if c.args]
        assert "test@test.com" in typed + filled


class TestClick:
    @pytest.mark.asyncio
    async def test_click_element(self, player, mock_page):
        el = _element()
        mock_page.query_selector.return_value = el

        await player._click(mock_page, "button.submit", timeout=1)
        el.click.assert_called_once()

    @pytest.mark.asyncio
    async def test_click_timeout(self, player, mock_page):
        mock_page.query_selector.return_value = None

        with pytest.raises(RuntimeError, match="Could not click"):
            await player._click(mock_page, "button.missing", timeout=1)


class TestSelect:
    @pytest.mark.asyncio
    async def test_select_radio_button(self, mock_page):
        el = _element(evaluate="INPUT")  # tagName
        mock_page.query_selector.return_value = el

        result = await _run(mock_page, [{"action": "select", "selector": 'input[name="size"][value="small"]', "value": "small"}])

        assert result["status"] == "success"
        el.click.assert_called_once()

    @pytest.mark.asyncio
    async def test_select_dropdown(self, mock_page):
        el = _element(evaluate="SELECT")
        mock_page.query_selector.return_value = el

        result = await _run(mock_page, [{"action": "select", "selector": "select[name='color']", "value": "red"}])

        assert result["status"] == "success"
        el.select_option.assert_called_once_with("red")


class TestResolveDate:
    def test_yesterday(self, player):
        result = player._resolve_date("yesterday")
        assert "/" in result  # dd/mm/yyyy format

    def test_today(self, player):
        result = player._resolve_date("today")
        today = datetime.now().strftime("%d/%m/%Y")
        assert result == today

    def test_passthrough(self, player):
        assert player._resolve_date("15/03/2026") == "15/03/2026"


class TestRun:
    @pytest.mark.asyncio
    async def test_run_empty_steps(self, mock_page):
        result = await _run(mock_page, [])
        assert result["status"] == "success"
        mock_page.goto.assert_called()  # navigates to URL

    @pytest.mark.asyncio
    async def test_run_fill_step(self, mock_page):
        mock_page.query_selector.return_value = _element()
        result = await _run(mock_page, [{"action": "fill", "selector": "input", "value": "test"}])
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_click_step(self, mock_page):
        mock_page.query_selector.return_value = _element()
        result = await _run(mock_page, [{"action": "click", "selector": "button"}])
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_select_step(self, mock_page):
        mock_page.query_selector.return_value = _element(evaluate="INPUT")
        result = await _run(mock_page, [{"action": "select", "selector": "input[name='x']", "value": "y"}])
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_check_step(self, mock_page):
        el = _element()
        mock_page.query_selector.return_value = el
        result = await _run(mock_page, [{"action": "check", "selector": "input[type='checkbox']", "checked": True}])
        assert result["status"] == "success"
        el.set_checked.assert_awaited_once_with(True)

    @pytest.mark.asyncio
    async def test_run_wait_step(self, mock_page):
        result = await _run(mock_page, [{"action": "wait", "seconds": 0.1}])
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_keyboard_step(self, mock_page):
        result = await _run(mock_page, [{"action": "keyboard", "key": "Enter"}])
        assert result["status"] == "success"
        mock_page.keyboard.press.assert_called_with("Enter")

    @pytest.mark.asyncio
    async def test_run_scrape_text_step(self, mock_page):
        mock_page.evaluate.return_value = "Page content here"

        result = await _run(mock_page, [{"action": "scrape_text"}])
        assert result["status"] == "success"
        assert len(result["scraped_data"]) == 1
        assert result["scraped_data"][0]["type"] == "text"
        assert result["scraped_data"][0]["data"] == "Page content here"

    @pytest.mark.asyncio
    async def test_run_screenshot_step(self, mock_page):
        result = await _run(mock_page, [{"action": "screenshot", "name": "test_shot"}])
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_navigate_step(self, mock_page):
        result = await _run(mock_page, [{"action": "navigate", "url": "https://other.com"}])
        assert result["status"] == "success"
        # Should have navigated twice: initial URL + navigate step
        assert mock_page.goto.call_count == 2

    @pytest.mark.asyncio
    async def test_run_unknown_action_fails_the_run(self, mock_page):
        # The contract refuses unknown actions at the door; if one reaches the
        # player anyway, it fails the run instead of being skipped.
        result = await _run(mock_page, [{"action": "dance"}])
        assert result["status"] == "error"
        assert "dance" in result["error"]

    @pytest.mark.asyncio
    async def test_run_error_returns_error_status(self, mock_page):
        mock_page.goto.side_effect = Exception("Connection refused")

        result = await _run(mock_page, [])
        assert result["status"] == "error"
        assert "Connection refused" in result["error"]

    @pytest.mark.asyncio
    async def test_run_multiple_steps(self, mock_page):
        mock_page.query_selector.return_value = _element(is_checked=False, evaluate="INPUT")

        result = await _run(mock_page, [
            {"action": "fill", "selector": "input[name='name']", "value": "John"},
            {"action": "select", "selector": "input[name='size']", "value": "large"},
            {"action": "check", "selector": "input[name='agree']", "checked": True},
            {"action": "click", "selector": "button"},
        ])
        assert result["status"] == "success"
        assert result["output"] == "Completed 4 steps"
