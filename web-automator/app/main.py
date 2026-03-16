"""
Web Automator — FastAPI application.

Provides REST API for browser recording and headless replay.
Runs inside Docker with Xvfb + noVNC for recording sessions.
"""

import asyncio
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import FastAPI, HTTPException

from .browser import browser_manager
from .display import display_manager
from .models import (
    HealthResponse, StatusResponse, SessionState,
    RecordRequest, RecordStartResponse, RecordStopResponse,
    PlayRequest, PlayResponse,
)
from .recorder import Recorder
from .player import Player

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

# --- App state ---

class AppState:
    def __init__(self):
        self.state: SessionState = SessionState.idle
        self.session_id: str | None = None
        self.started_at: str | None = None
        self.recorder: Recorder | None = None
        self.context = None  # BrowserContext
        self.page = None     # Page
        self._play_task: asyncio.Task | None = None

app_state = AppState()


# --- Lifespan ---

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Web Automator starting up")
    yield
    logger.info("Web Automator shutting down")
    await _cleanup()


app = FastAPI(
    title="Web Automator",
    version="1.0.0",
    lifespan=lifespan,
)


async def _cleanup():
    """Clean up browser and display resources."""
    if app_state.context:
        try:
            await app_state.context.close()
        except Exception:
            pass
        app_state.context = None
        app_state.page = None

    await browser_manager.close()
    app_state.state = SessionState.idle
    app_state.session_id = None
    app_state.recorder = None


# --- Endpoints ---

@app.get("/health", response_model=HealthResponse)
async def health():
    return HealthResponse()


@app.get("/status", response_model=StatusResponse)
async def status():
    return StatusResponse(
        state=app_state.state,
        session_id=app_state.session_id,
        started_at=app_state.started_at,
    )


@app.post("/record", response_model=RecordStartResponse)
async def start_recording(req: RecordRequest):
    if app_state.state != SessionState.idle:
        raise HTTPException(400, f"Cannot record: currently {app_state.state.value}")

    session_id = str(uuid.uuid4())[:8]

    # Launch headed browser on Xvfb display (fixed viewport for readability via noVNC)
    display_manager.start()
    browser = await browser_manager.launch(headless=False)
    context = await browser_manager.new_context(
        viewport_override={"width": 1366, "height": 768},
        force_scale_factor=1,
    )
    page = await context.new_page()

    # Set up recorder
    recorder = Recorder(
        session_id=session_id,
        base_url=req.url,
        patterns=req.patterns if req.patterns else None,
    )
    await recorder.start(page)

    # Update state
    app_state.state = SessionState.recording
    app_state.session_id = session_id
    app_state.started_at = datetime.now().isoformat()
    app_state.recorder = recorder
    app_state.context = context
    app_state.page = page

    novnc_url = display_manager.novnc_url
    logger.info("Recording started: session=%s, url=%s", session_id, req.url)

    return RecordStartResponse(session_id=session_id, novnc_url=novnc_url)


@app.post("/record/{session_id}/stop", response_model=RecordStopResponse)
async def stop_recording(session_id: str):
    if app_state.state != SessionState.recording:
        raise HTTPException(400, "No recording in progress")
    if app_state.session_id != session_id:
        raise HTTPException(404, f"Session {session_id} not found")

    results = await app_state.recorder.async_stop()
    await _cleanup()

    return RecordStopResponse(
        actions=results["actions"],
        downloads=results["downloads"],
        summary=results["summary"],
    )


@app.post("/play", response_model=PlayResponse)
async def play(req: PlayRequest):
    if app_state.state != SessionState.idle:
        raise HTTPException(400, f"Cannot play: currently {app_state.state.value}")

    app_state.state = SessionState.playing
    app_state.session_id = str(uuid.uuid4())[:8]
    app_state.started_at = datetime.now().isoformat()

    try:
        browser = await browser_manager.launch(headless=True)
        context = await browser_manager.new_context()
        page = await context.new_page()
        page.set_default_timeout(req.config.get("page_timeout", 60) * 1000)

        app_state.context = context
        app_state.page = page

        player = Player(req.config)
        result = await player.run(page)

        return PlayResponse(**result)

    except Exception as e:
        logger.error("Play failed: %s", e)
        return PlayResponse(status="error", error=str(e))

    finally:
        await _cleanup()


@app.post("/stop")
async def force_stop():
    if app_state.state == SessionState.idle:
        return {"message": "Already idle"}

    prev_state = app_state.state.value
    await _cleanup()
    return {"message": f"Stopped (was {prev_state})"}
