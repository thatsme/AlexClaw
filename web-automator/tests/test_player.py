"""Tests for the Player class — action execution logic.

Tests the action handlers without a real browser by mocking the Page object.
"""

import pytest
from unittest.mock import AsyncMock, MagicMock, patch
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
    return page


class TestPlayerInit:
    def test_defaults(self, player):
        assert player.downloads == []
        assert player.screenshots == []
        assert player.scraped_data == []

    def test_custom_output_dir(self):
        p = Player(config={"output_dir": "/tmp/custom"})
        assert p.output_dir == "/tmp/custom"


class TestNavigate:
    @pytest.mark.asyncio
    async def test_navigate(self, player, mock_page):
        await player._navigate(mock_page, "https://example.com/page")
        mock_page.goto.assert_called_once_with(
            "https://example.com/page", wait_until="domcontentloaded"
        )


class TestFill:
    @pytest.mark.asyncio
    async def test_fill_text_field(self, player, mock_page):
        el = AsyncMock()
        mock_page.query_selector.return_value = el

        await player._fill(mock_page, "input[name='email']", "test@test.com")

        mock_page.query_selector.assert_called_with("input[name='email']")
        el.click.assert_called_once()
        mock_page.keyboard.press.assert_called_with("Control+a")
        mock_page.keyboard.type.assert_called_once()
        # Check value passed
        call_args = mock_page.keyboard.type.call_args
        assert call_args[0][0] == "test@test.com"

    @pytest.mark.asyncio
    async def test_fill_selector_not_found(self, player, mock_page):
        mock_page.query_selector.return_value = None
        # Should not raise
        await player._fill(mock_page, "input.missing", "value")


class TestClick:
    @pytest.mark.asyncio
    async def test_click_element(self, player, mock_page):
        el = AsyncMock()
        el.is_visible.return_value = True
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
    async def test_select_radio_button(self, player, mock_page):
        el = AsyncMock()
        el.evaluate.return_value = "INPUT"  # tagName
        mock_page.query_selector.return_value = el

        await player._select(mock_page, 'input[name="size"][value="small"]', "small")
        el.click.assert_called_once()

    @pytest.mark.asyncio
    async def test_select_dropdown(self, player, mock_page):
        el = AsyncMock()
        el.evaluate.return_value = "SELECT"
        mock_page.query_selector.return_value = el

        await player._select(mock_page, "select[name='color']", "red")
        el.select_option.assert_called_once_with("red")

    @pytest.mark.asyncio
    async def test_select_not_found(self, player, mock_page):
        mock_page.query_selector.return_value = None
        await player._select(mock_page, "input.missing", "value")


class TestCheck:
    @pytest.mark.asyncio
    async def test_check_unchecked_checkbox(self, player, mock_page):
        el = AsyncMock()
        el.is_checked.return_value = False
        mock_page.query_selector.return_value = el

        await player._check(mock_page, 'input[name="agree"]', "on")
        el.click.assert_called_once()

    @pytest.mark.asyncio
    async def test_check_already_checked(self, player, mock_page):
        el = AsyncMock()
        el.is_checked.return_value = True
        mock_page.query_selector.return_value = el

        await player._check(mock_page, 'input[name="agree"]', "on")
        el.click.assert_not_called()

    @pytest.mark.asyncio
    async def test_check_not_found(self, player, mock_page):
        mock_page.query_selector.return_value = None
        await player._check(mock_page, "input.missing", "value")


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
        player = Player(config={"url": "https://example.com", "steps": []})
        result = await player.run(mock_page)
        assert result["status"] == "success"
        mock_page.goto.assert_called()  # navigates to URL

    @pytest.mark.asyncio
    async def test_run_fill_step(self, mock_page):
        el = AsyncMock()
        mock_page.query_selector.return_value = el

        player = Player(config={
            "url": "https://example.com",
            "steps": [{"action": "fill", "selector": "input", "value": "test"}],
        })
        result = await player.run(mock_page)
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_click_step(self, mock_page):
        el = AsyncMock()
        el.is_visible.return_value = True
        mock_page.query_selector.return_value = el

        player = Player(config={
            "url": "https://example.com",
            "steps": [{"action": "click", "selector": "button"}],
        })
        result = await player.run(mock_page)
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_select_step(self, mock_page):
        el = AsyncMock()
        el.evaluate.return_value = "INPUT"
        mock_page.query_selector.return_value = el

        player = Player(config={
            "url": "https://example.com",
            "steps": [{"action": "select", "selector": "input[name='x']", "value": "y"}],
        })
        result = await player.run(mock_page)
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_check_step(self, mock_page):
        el = AsyncMock()
        el.is_checked.return_value = False
        mock_page.query_selector.return_value = el

        player = Player(config={
            "url": "https://example.com",
            "steps": [{"action": "check", "selector": "input[type='checkbox']", "value": "on"}],
        })
        result = await player.run(mock_page)
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_wait_step(self, mock_page):
        player = Player(config={
            "url": "https://example.com",
            "steps": [{"action": "wait", "value": "0.1"}],
        })
        result = await player.run(mock_page)
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_keyboard_step(self, mock_page):
        player = Player(config={
            "url": "https://example.com",
            "steps": [{"action": "keyboard", "value": "Enter"}],
        })
        result = await player.run(mock_page)
        assert result["status"] == "success"
        mock_page.keyboard.press.assert_called_with("Enter")

    @pytest.mark.asyncio
    async def test_run_scrape_text_step(self, mock_page):
        mock_page.evaluate.return_value = "Page content here"

        player = Player(config={
            "url": "https://example.com",
            "steps": [{"action": "scrape_text"}],
        })
        result = await player.run(mock_page)
        assert result["status"] == "success"
        assert len(result["scraped_data"]) == 1
        assert result["scraped_data"][0]["type"] == "text"
        assert result["scraped_data"][0]["data"] == "Page content here"

    @pytest.mark.asyncio
    async def test_run_screenshot_step(self, mock_page):
        player = Player(config={
            "url": "https://example.com",
            "steps": [{"action": "screenshot", "value": "test_shot"}],
        })
        result = await player.run(mock_page)
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_navigate_step(self, mock_page):
        player = Player(config={
            "url": "https://example.com",
            "steps": [{"action": "navigate", "url": "https://other.com"}],
        })
        result = await player.run(mock_page)
        assert result["status"] == "success"
        # Should have navigated twice: initial URL + navigate step
        assert mock_page.goto.call_count == 2

    @pytest.mark.asyncio
    async def test_run_unknown_action(self, mock_page):
        player = Player(config={
            "url": "https://example.com",
            "steps": [{"action": "dance"}],
        })
        result = await player.run(mock_page)
        # Unknown actions are warned but don't fail
        assert result["status"] == "success"

    @pytest.mark.asyncio
    async def test_run_error_returns_error_status(self, mock_page):
        mock_page.goto.side_effect = Exception("Connection refused")

        player = Player(config={
            "url": "https://example.com",
            "steps": [],
        })
        result = await player.run(mock_page)
        assert result["status"] == "error"
        assert "Connection refused" in result["error"]

    @pytest.mark.asyncio
    async def test_run_multiple_steps(self, mock_page):
        el = AsyncMock()
        el.is_visible.return_value = True
        el.is_checked.return_value = False
        el.evaluate.return_value = "INPUT"
        mock_page.query_selector.return_value = el

        player = Player(config={
            "url": "https://example.com",
            "steps": [
                {"action": "fill", "selector": "input[name='name']", "value": "John"},
                {"action": "select", "selector": "input[name='size']", "value": "large"},
                {"action": "check", "selector": "input[name='agree']", "value": "on"},
                {"action": "click", "selector": "button"},
            ],
        })
        result = await player.run(mock_page)
        assert result["status"] == "success"
        assert result["output"] == "Completed 4 steps"
