"""Pydantic models for web-automator API request/response."""

from datetime import datetime
from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, Field


# --- Enums ---

class SessionState(str, Enum):
    idle = "idle"
    recording = "recording"
    playing = "playing"


class ActionType(str, Enum):
    navigate = "navigate"
    click = "click"
    fill = "fill"
    select = "select"
    download_click = "download_click"
    keyboard = "keyboard"
    wait = "wait"
    login = "login"
    interaction = "interaction"


# --- Captured data ---

class CapturedAction(BaseModel):
    timestamp: str
    action_type: str
    description: str
    selector: Optional[str] = None
    value: Optional[str] = None
    url: Optional[str] = None
    post_data: Optional[str] = None
    headers: Optional[dict] = None


class DownloadedFile(BaseModel):
    timestamp: str
    filename: str
    url: str
    saved_to: str
    trigger_action: Optional[str] = None


# --- Request models ---

class RecordRequest(BaseModel):
    url: str
    patterns: list[str] = Field(default_factory=lambda: [
        "download", "export", "filter", "button", "login", "menu", "submit"
    ])
    timeout: int = 300


class PlayRequest(BaseModel):
    config: dict[str, Any]


class InteractStep(BaseModel):
    """A single interaction step in an automation config."""
    action: str  # navigate, click, fill, select, wait, keyboard, download
    selector: Optional[str] = None
    value: Optional[str] = None
    url: Optional[str] = None
    timeout: Optional[int] = None
    description: Optional[str] = None


# --- Response models ---

class RecordStartResponse(BaseModel):
    session_id: str
    novnc_url: str


class RecordStopResponse(BaseModel):
    actions: list[CapturedAction]
    downloads: list[DownloadedFile]
    summary: dict


class PlayResponse(BaseModel):
    status: str
    output: Optional[str] = None
    downloads: list[str] = Field(default_factory=list)
    screenshots: list[str] = Field(default_factory=list)
    scraped_data: list[dict] = Field(default_factory=list)
    error: Optional[str] = None


class StatusResponse(BaseModel):
    state: SessionState
    session_id: Optional[str] = None
    started_at: Optional[str] = None
    progress: Optional[str] = None


class ScrapeRequest(BaseModel):
    url: str
    selector: str = "table"  # CSS selector for target elements
    format: str = "json"     # json or csv
    wait: int = 3            # seconds to wait for page to settle


class ScrapeResponse(BaseModel):
    status: str
    url: str
    tables: list[dict] = Field(default_factory=list)
    error: Optional[str] = None


class HealthResponse(BaseModel):
    status: str = "ok"
    version: str = "1.0.0"
