"""
Web Automator — FastAPI application.

Provides REST API for browser recording and headless replay.
Runs inside Docker with Xvfb + noVNC for recording sessions.
"""

import asyncio
import hmac
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.datastructures import Headers

from .browser import BrowserManager, browser_manager
from .egress import EgressProxy
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
        self.context = None  # BrowserContext (recording)
        self.page = None     # Page (recording)
        # The running play, if any: its id, its task, and whether it was asked to stop.
        self.play_id: str | None = None
        self.play_task: asyncio.Task | None = None
        self.play_stopping: bool = False

app_state = AppState()


# --- A play's own browser ---

class PlaySession:
    """One play's browser: its egress proxy, browser, context and page. Nothing
    is shared between plays, so closing one never touches another."""

    def __init__(self, proxy: EgressProxy, manager: BrowserManager, context, page):
        self._proxy = proxy
        self._manager = manager
        self._context = context
        self.page = page

    async def close(self):
        try:
            await self._context.close()
        except Exception:
            pass
        await self._manager.close()
        await self._proxy.stop()


async def open_play_session() -> PlaySession:
    """A new browser, forced through a new egress proxy, for one play."""
    proxy = EgressProxy()
    manager = BrowserManager()
    try:
        proxy_port = await proxy.start()
        await manager.launch(headless=True, proxy_port=proxy_port)
        context = await manager.new_context()
        page = await context.new_page()
        page.set_default_timeout(60_000)
        return PlaySession(proxy, manager, context, page)
    except BaseException:
        await manager.close()
        await proxy.stop()
        raise


# --- Lifespan ---

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Web Automator starting up")
    yield
    logger.info("Web Automator shutting down")
    await _cleanup()


# No interactive docs: they would describe every route to anyone who asks.
app = FastAPI(
    title="Web Automator",
    version="1.0.0",
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


# --- Authentication ---

class RequireToken:
    """Every route but /health needs `Authorization: Bearer <WEB_AUTOMATOR_TOKEN>`.

    The token is read at request time. With none configured every protected
    route answers 503: the sidecar never falls back to open. A plain ASGI
    middleware, so the endpoint still sees the client's disconnect (/play
    cancels on it).
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["path"] == "/health":
            return await self.app(scope, receive, send)

        expected = os.environ.get("WEB_AUTOMATOR_TOKEN", "")
        if not expected:
            response = JSONResponse({"detail": "WEB_AUTOMATOR_TOKEN is not configured"}, status_code=503)
        elif not _bearer_matches(Headers(scope=scope).get("authorization", ""), expected):
            response = JSONResponse(
                {"detail": "Unauthorized"}, status_code=401, headers={"WWW-Authenticate": "Bearer"}
            )
        else:
            return await self.app(scope, receive, send)

        await response(scope, receive, send)


app.add_middleware(RequireToken)


def _bearer_matches(header: str, expected: str) -> bool:
    scheme, _, token = header.partition(" ")
    return scheme == "Bearer" and hmac.compare_digest(token.encode(), expected.encode())


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
        play_id=app_state.play_id,
        started_at=app_state.started_at,
    )


@app.post("/record", response_model=RecordStartResponse)
async def start_recording(req: RecordRequest):
    if app_state.state != SessionState.idle:
        raise HTTPException(409, f"Cannot record: currently {app_state.state.value}")

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
async def play(req: PlayRequest, request: Request):
    """Run one recipe in its own browser, bounded by `deadline_ms`, cancelled if
    the client goes away or POST /play/{play_id}/stop asks for it."""
    if app_state.state != SessionState.idle:
        raise HTTPException(409, f"Cannot play: currently {app_state.state.value}")

    play_id = req.play_id
    app_state.state = SessionState.playing
    app_state.session_id = play_id
    app_state.play_id = play_id
    app_state.play_stopping = False
    app_state.started_at = datetime.now().isoformat()

    task = asyncio.create_task(_run_play(req.config.model_dump(exclude_none=True)))
    app_state.play_task = task
    watcher = asyncio.create_task(_cancel_on_disconnect(request, task))

    try:
        result = await asyncio.wait_for(task, timeout=req.deadline_ms / 1000)
        return PlayResponse(**result)
    except asyncio.TimeoutError:
        logger.warning("Play %s: deadline of %d ms exceeded", play_id, req.deadline_ms)
        return PlayResponse(status="timeout", error=f"deadline of {req.deadline_ms} ms exceeded")
    except asyncio.CancelledError:
        if not task.cancelled():
            raise
        logger.info("Play %s: stopped", play_id)
        return PlayResponse(status="stopped", error="stopped before it finished")
    except Exception as e:
        logger.error("Play %s failed: %s", play_id, type(e).__name__)
        return PlayResponse(status="error", error=str(e))
    finally:
        watcher.cancel()
        # Only this play's own state: a later play may already be running.
        if app_state.play_id == play_id:
            app_state.state = SessionState.idle
            app_state.session_id = None
            app_state.play_id = None
            app_state.play_task = None
            app_state.play_stopping = False


async def _run_play(recipe: dict) -> dict:
    session = await open_play_session()
    try:
        return await Player(recipe).run(session.page)
    finally:
        await session.close()


async def _cancel_on_disconnect(request: Request, task: asyncio.Task):
    while not task.done():
        if await request.is_disconnected():
            logger.info("Play client went away; cancelling the play")
            task.cancel()
            return
        await asyncio.sleep(0.25)


@app.post("/play/{play_id}/stop")
async def stop_play(play_id: str):
    """Stop the running play if it is `play_id`; any other id is 404."""
    task = app_state.play_task
    if app_state.play_id != play_id or task is None or task.done():
        raise HTTPException(404, f"Play {play_id} is not running")

    app_state.play_stopping = True
    task.cancel()
    return {"message": f"Stopping play {play_id}"}


@app.post("/stop")
async def force_stop():
    if app_state.state == SessionState.idle:
        return {"message": "Already idle"}

    prev_state = app_state.state.value
    if app_state.play_task is not None and not app_state.play_task.done():
        app_state.play_stopping = True
        app_state.play_task.cancel()
    else:
        await _cleanup()
    return {"message": f"Stopped (was {prev_state})"}
