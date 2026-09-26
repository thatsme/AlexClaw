"""A login is typed only on a page of the origin it is bound to (S8 H2/H3).

AlexClaw marks each fill that types a login with the origin the login is bound
to (`origin`, scheme://host[:port]). Before typing it, the player checks the
page it is on: a page that navigated or was redirected to another origin fails
the run, naming the selector, and nothing is typed. A fill without an origin
(an ordinary value) is typed wherever the recipe is.
"""

from unittest.mock import AsyncMock, MagicMock

import pytest

from app.player import Player

LOGIN = "not-a-real-login-value"


def _page(url):
    page = AsyncMock()
    page.keyboard = AsyncMock()
    page.frames = [page]
    page.url = url
    page.goto.return_value = MagicMock(headers={}, status=200)
    page.query_selector.return_value = AsyncMock()  # the field is there
    return page


def _typed(page):
    return [call.args[0] for call in page.keyboard.type.await_args_list]


def _login_fill(origin):
    return {"action": "fill", "selector": "#password", "value": LOGIN, "origin": origin, "timeout_ms": 1000}


def _play(steps, url="https://bank.example.com/login"):
    return Player(config={"url": url, "steps": steps})


class TestLoginOnItsOrigin:
    @pytest.mark.asyncio
    async def test_typed_on_a_page_of_its_origin(self):
        page = _page("https://bank.example.com/login?next=/")

        result = await _play([_login_fill("https://bank.example.com")]).run(page)

        assert result["status"] == "success", result
        assert _typed(page) == [LOGIN]

    @pytest.mark.asyncio
    async def test_default_port_and_case_do_not_matter(self):
        page = _page("https://Bank.Example.com:443/login")

        result = await _play([_login_fill("https://bank.example.com")]).run(page)

        assert result["status"] == "success", result
        assert _typed(page) == [LOGIN]

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "page_url",
        [
            "https://evil.example.net/login",
            "http://bank.example.com/login",
            "https://bank.example.com:8443/login",
            "https://bank.example.com.evil.example.net/login",
        ],
        ids=["another host", "another scheme", "another port", "a lookalike host"],
    )
    async def test_refused_on_another_origin(self, page_url):
        page = _page(page_url)

        result = await _play([_login_fill("https://bank.example.com")]).run(page)

        assert result["status"] == "error"
        assert "#password" in result["error"]
        assert LOGIN not in str(result)
        assert _typed(page) == [], "the login was typed on another origin"


class TestOrdinaryFill:
    @pytest.mark.asyncio
    async def test_a_fill_without_an_origin_is_typed_where_the_page_is(self):
        page = _page("https://elsewhere.example.org/search")

        result = await _play([{"action": "fill", "selector": "#q", "value": "reports", "timeout_ms": 1000}]).run(page)

        assert result["status"] == "success", result
        assert _typed(page) == ["reports"]
