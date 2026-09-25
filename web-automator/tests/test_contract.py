"""The recipe contract, sidecar side (reports/WEB_AUTOMATOR_TARGET.md §2).

The /play config was an untyped dict that neither side validated, so the two
sides drifted: uncheck replayed as check, five recorded names were skipped as
"Unknown action", `evaluate` and `output_dir` went through untouched. Now a
recipe is validated at the door by a strict pydantic model, against the same
fixture file AlexClaw validates against (tests/contract/recipes.json).

- app.recipe.Recipe accepts every valid fixture and refuses every invalid one;
- app.recipe.ACTIONS is exactly contract/actions.json, and every action has a
  valid fixture;
- /play refuses an invalid recipe with 422 before any browser is launched;
- busy is 409, not 400.
"""

import json
from pathlib import Path
from unittest.mock import AsyncMock, patch
from tests.token_file import use_token

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.main import app, app_state, SessionState
from app.recipe import ACTIONS, Recipe

CONTRACT = Path(__file__).parent / "contract"
FIXTURES = json.loads((CONTRACT / "recipes.json").read_text())
CONTRACT_ACTIONS = json.loads((CONTRACT / "actions.json").read_text())

TOKEN = "test-automator-token"

# /play's request-level fields (test_lifecycle.py); the recipe is `config`.
PLAY = {"play_id": "p-contract1", "deadline_ms": 60_000}


def _ids(cases):
    return [case["name"] for case in cases]


@pytest.mark.parametrize("case", FIXTURES["valid"], ids=_ids(FIXTURES["valid"]))
def test_every_valid_recipe_is_accepted(case):
    Recipe.model_validate(case["recipe"])


@pytest.mark.parametrize("case", FIXTURES["invalid"], ids=_ids(FIXTURES["invalid"]))
def test_every_invalid_recipe_is_refused(case):
    with pytest.raises(ValidationError):
        Recipe.model_validate(case["recipe"])


def test_the_action_set_is_the_contract():
    assert sorted(ACTIONS) == sorted(CONTRACT_ACTIONS)


def test_every_action_has_a_valid_fixture():
    used = {step["action"] for case in FIXTURES["valid"] for step in case["recipe"]["steps"]}
    assert set(CONTRACT_ACTIONS) - used == set()


@pytest.fixture
def client(monkeypatch):
    use_token(monkeypatch, TOKEN)
    app_state.state = SessionState.idle
    yield TestClient(app, headers={"Authorization": f"Bearer {TOKEN}"})
    app_state.state = SessionState.idle


class TestPlayEndpoint:
    @pytest.mark.parametrize("case", FIXTURES["invalid"], ids=_ids(FIXTURES["invalid"]))
    def test_an_invalid_recipe_is_422_and_launches_nothing(self, client, case):
        with patch("app.main.open_play_session", new=AsyncMock()) as opener:
            resp = client.post("/play", json={**PLAY, "config": case["recipe"]})

        assert resp.status_code == 422, resp.text
        opener.assert_not_called()
        assert app_state.state == SessionState.idle

    def test_a_request_with_extra_top_level_fields_is_422(self, client):
        with patch("app.main.open_play_session", new=AsyncMock()) as opener:
            resp = client.post(
                "/play",
                json={**PLAY, "config": {"url": "https://example.com", "steps": []}, "output_dir": "/etc"},
            )

        assert resp.status_code == 422
        opener.assert_not_called()


class TestBusy:
    def test_play_while_playing_is_409(self, client):
        app_state.state = SessionState.playing
        resp = client.post("/play", json={**PLAY, "config": {"url": "https://example.com", "steps": []}})
        assert resp.status_code == 409

    def test_record_while_playing_is_409(self, client):
        app_state.state = SessionState.playing
        resp = client.post("/record", json={"url": "https://example.com"})
        assert resp.status_code == 409

    def test_play_while_recording_is_409(self, client):
        app_state.state = SessionState.recording
        resp = client.post("/play", json={**PLAY, "config": {"url": "https://example.com", "steps": []}})
        assert resp.status_code == 409
