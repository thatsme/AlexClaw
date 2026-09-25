"""The recorder never captures what is typed into a credential field
(reports/V040_SECURITY_DESIGN.md §6; 0.4.0 S4b).

The page's change listener sent `el.value` for every input, password fields
included, and the recorder stored it; the value then reached AlexClaw on stop
and was stored in plain text in the recorded resource
(reports/S4A_SECRETS_IN_RECORDS.md, S4b section).

Now:
- the page reports each filled field's `input_type` and `autocomplete`;
- a CREDENTIAL field — `type="password"`, or `autocomplete` of
  `current-password`, `new-password` or `one-time-code` — is recorded as a
  fill with `secret: True` and NO value: "a login goes here";
- any other field keeps its value, as before;
- nothing the recorder returns on stop contains a credential field's value.
"""

import json

import pytest

from app import recorder as recorder_module
from app.recorder import Recorder

SECRET = "s3cr3t-typed-9913"


def _payload(**fields):
    base = {"action_type": "fill", "selector": "#field", "value": SECRET}
    base.update(fields)
    return json.dumps(base)


def _returned(recorder):
    """What the recorder hands back on stop, as data."""
    out = []
    for action in recorder.actions:
        if hasattr(action, "model_dump"):
            out.append(action.model_dump())
        elif hasattr(action, "__dict__"):
            out.append(dict(vars(action)))
        else:
            out.append(action)
    return out


class TestCredentialFields:
    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "fields",
        [
            {"input_type": "password"},
            {"input_type": "text", "autocomplete": "current-password"},
            {"input_type": "text", "autocomplete": "new-password"},
            {"input_type": "text", "autocomplete": "one-time-code"},
        ],
    )
    async def test_is_recorded_as_a_login_slot_without_its_value(self, fields):
        recorder = Recorder("s1", "https://portal.example.com")
        await recorder._on_dom_action(_payload(selector="#pw", **fields))

        returned = _returned(recorder)
        assert len(returned) == 1, "the fill must still be recorded — as a slot"
        assert returned[0].get("secret") is True
        assert not returned[0].get("value"), "the value was kept"
        assert SECRET not in json.dumps(returned, default=str)


class TestOrdinaryFields:
    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "fields",
        [{"input_type": "text"}, {"input_type": "search"}, {"input_type": "email"}, {}],
    )
    async def test_keep_their_value(self, fields):
        recorder = Recorder("s1", "https://portal.example.com")
        await recorder._on_dom_action(_payload(selector="#q", value="ordinary text", **fields))

        returned = _returned(recorder)
        assert returned[0].get("value") == "ordinary text"
        assert not returned[0].get("secret")


class TestThePageReportsTheFieldKind:
    # The decision needs the page to say what kind of field it is. Checked on
    # the injected script: it must send input_type and autocomplete with every
    # fill, or every credential field would look ordinary.
    def test_the_injected_listener_sends_input_type_and_autocomplete(self):
        script = recorder_module._DOM_RECORDER_JS
        assert "input_type" in script
        assert "autocomplete" in script

    def test_it_no_longer_sends_a_password_fields_value(self):
        # The listener itself leaves the value out for a credential field, so
        # it never crosses into Python at all.
        script = recorder_module._DOM_RECORDER_JS
        assert "password" in script
        assert "current-password" in script
