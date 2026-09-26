"""The recipe contract: what /play accepts.

A recipe is exactly {url, steps}. Every step names one action and carries only
that action's fields, plus an optional timeout_ms; unknown keys anywhere are
refused. A fill that types a login carries the origin the login is bound to,
and is typed only on a page of that origin. The same contract is enforced on the AlexClaw side
(AlexClaw.WebAutomation.Recipe), and both are tested against
tests/contract/recipes.json.
"""

from typing import Annotated, Literal, Optional, Union
from urllib.parse import urlsplit

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    StrictBool,
    StrictFloat,
    StrictInt,
    StrictStr,
)


def _http_url(value: str) -> str:
    parts = urlsplit(value)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError("must be an http(s) URL with a host")
    return value


def _origin(value: str) -> str:
    parts = urlsplit(value)
    if parts.path or parts.query or parts.fragment or "@" in parts.netloc:
        raise ValueError("must be an http(s) origin: scheme://host[:port]")
    return _http_url(value)


HttpUrl = Annotated[StrictStr, AfterValidator(_http_url)]
Origin = Annotated[StrictStr, AfterValidator(_origin)]
Selector = Annotated[StrictStr, Field(min_length=1)]
TimeoutMs = Annotated[StrictInt, Field(ge=1, le=120_000)]


class _Step(BaseModel):
    model_config = ConfigDict(extra="forbid")

    timeout_ms: Optional[TimeoutMs] = None


class Navigate(_Step):
    action: Literal["navigate"]
    url: HttpUrl


class Click(_Step):
    action: Literal["click"]
    selector: Selector


class Fill(_Step):
    action: Literal["fill"]
    selector: Selector
    value: StrictStr
    input_type: Optional[Literal["date"]] = None
    # A login is typed only on a page of the origin it is bound to (player).
    origin: Optional[Origin] = None


class Select(_Step):
    action: Literal["select"]
    selector: Selector
    value: StrictStr


class Check(_Step):
    action: Literal["check"]
    selector: Selector
    checked: StrictBool


class Wait(_Step):
    action: Literal["wait"]
    seconds: Annotated[Union[StrictInt, StrictFloat], Field(gt=0, le=60)]


class Keyboard(_Step):
    action: Literal["keyboard"]
    key: Annotated[StrictStr, Field(min_length=1)]


class Download(_Step):
    action: Literal["download"]
    selector: Selector


class Scrape(_Step):
    action: Literal["scrape"]
    selector: Optional[Selector] = None


class ScrapeText(_Step):
    action: Literal["scrape_text"]
    selector: Optional[Selector] = None


class ExtractGrid(_Step):
    action: Literal["extract_grid"]
    selector: Selector


class Screenshot(_Step):
    action: Literal["screenshot"]
    name: Optional[Annotated[StrictStr, Field(pattern=r"^[a-z0-9_-]{1,40}$")]] = None
    full_page: Optional[StrictBool] = None


_STEPS = (Navigate, Click, Fill, Select, Check, Wait, Keyboard, Download, Scrape, ScrapeText, ExtractGrid, Screenshot)

Step = Annotated[Union[_STEPS], Field(discriminator="action")]

ACTIONS = tuple(model.model_fields["action"].annotation.__args__[0] for model in _STEPS)


class Recipe(BaseModel):
    model_config = ConfigDict(extra="forbid")

    url: HttpUrl
    steps: list[Step]
