"""
Web interaction recorder — captures user actions for replay.

Generalized from TOS cone_sniffer.py. Intercepts network requests,
classifies actions, and tracks downloads.
"""

import asyncio
import logging
import os
import re
from dataclasses import dataclass, asdict, field
from datetime import datetime
from typing import Optional
from urllib.parse import urlparse

from patchright.async_api import Page, Request

logger = logging.getLogger(__name__)


@dataclass
class CapturedAction:
    """A meaningful user action captured during recording."""
    timestamp: str
    action_type: str  # login, navigate, click, fill, download_click, interaction
    description: str
    selector: Optional[str] = None
    value: Optional[str] = None
    url: Optional[str] = None
    post_data: Optional[str] = None
    headers: Optional[dict] = None


@dataclass
class DownloadedFile:
    """A file download captured during recording."""
    timestamp: str
    filename: str
    url: str
    saved_to: str
    trigger_action: Optional[str] = None


class Recorder:
    """
    Records user interactions with a website.

    Intercepts network requests, classifies meaningful actions,
    and tracks file downloads. Designed to run in a headed browser
    on Xvfb so users interact via noVNC.
    """

    def __init__(
        self,
        session_id: str,
        base_url: str,
        patterns: list[str] | None = None,
        output_dir: str = "/tmp/recordings",
    ):
        self.session_id = session_id
        self.base_url = base_url
        self.output_dir = output_dir

        self.interesting_patterns = patterns or [
            "download", "export", "filter", "button",
            "login", "menu", "submit", "search",
        ]

        self.actions: list[CapturedAction] = []
        self.downloads: list[DownloadedFile] = []
        self.request_count = 0
        self.ignored_count = 0
        self.last_action: Optional[CapturedAction] = None
        self._page: Optional[Page] = None

        os.makedirs(output_dir, exist_ok=True)

    # --- Static asset filter ---

    _IGNORE_EXTENSIONS = frozenset([
        ".svg", ".png", ".jpg", ".jpeg", ".gif", ".webp",
        ".css", ".js", ".woff", ".woff2", ".ttf", ".ico", ".map",
    ])

    def _is_interesting(self, request: Request) -> bool:
        """Determine if a request represents a meaningful user action."""
        url = request.url
        path = urlparse(url).path

        # Ignore static assets
        if any(path.endswith(ext) for ext in self._IGNORE_EXTENSIONS):
            self.ignored_count += 1
            return False

        # Ignore common heartbeat/polling endpoints
        lower_path = path.lower()
        if any(p in lower_path for p in ["/pong", "/heartbeat", "/health", "/ping"]):
            self.ignored_count += 1
            return False

        # For POST requests, check if content matches interesting patterns
        if request.method == "POST":
            post_data = request.post_data or ""
            combined = (path + post_data).lower()

            # Check URL path and headers for interesting patterns
            headers = request.headers
            for key, val in headers.items():
                if key.startswith("x-") and val:
                    combined += val.lower()

            if any(pattern in combined for pattern in self.interesting_patterns):
                return True

            # POST with body data is usually meaningful
            if post_data and len(post_data) > 2:
                return True

            self.ignored_count += 1
            return False

        # GET requests to API-like paths
        if request.method == "GET" and ("/api/" in path or "/v1/" in path or "/v2/" in path):
            return True

        # Page navigation
        if request.resource_type in ("document", "xhr", "fetch"):
            return True

        self.ignored_count += 1
        return False

    def _classify_action(self, request: Request) -> Optional[CapturedAction]:
        """Parse a request into a classified action."""
        url = request.url
        path = urlparse(url).path
        post_data = request.post_data
        method = request.method
        combined = (path + (post_data or "")).lower()

        action_type = "interaction"
        description = f"{method} {path}"

        if "login" in combined or "auth" in combined or "signin" in combined:
            action_type = "login"
            description = "Login/authentication request"
        elif any(kw in combined for kw in ["download", "export", "excel", "csv", "pdf"]):
            action_type = "download_click"
            fmt = "file"
            for f in ["excel", "csv", "pdf"]:
                if f in combined:
                    fmt = f
                    break
            description = f"Download triggered ({fmt})"
        elif "filter" in combined or "search" in combined or "query" in combined:
            action_type = "filter"
            description = f"Filter/search: {path}"
            if post_data and len(post_data) < 200:
                description += f" data={post_data[:100]}"
        elif request.resource_type == "document":
            action_type = "navigate"
            description = f"Navigate to {path}"
        elif "submit" in combined or method == "POST":
            action_type = "submit"
            description = f"Form submit: {path}"

        return CapturedAction(
            timestamp=datetime.now().isoformat(),
            action_type=action_type,
            description=description,
            url=url,
            post_data=post_data[:500] if post_data and len(post_data) < 500 else None,
            headers={k: v for k, v in request.headers.items() if k.startswith("x-")},
        )

    async def _on_request(self, request: Request):
        """Handle intercepted request — only used to flush DOM actions before navigations."""
        self.request_count += 1

        # Flush DOM actions before page navigations (form submits, link clicks)
        if request.resource_type == "document" and request.is_navigation_request():
            try:
                await self._flush_dom_actions()
            except Exception as e:
                logger.debug("Pre-navigation flush failed: %s", e)

    async def _on_download(self, download):
        """Handle file download."""
        filename = download.suggested_filename
        save_path = os.path.join(self.output_dir, filename)

        logger.info("DOWNLOAD: %s", filename)
        await download.save_as(save_path)

        dl = DownloadedFile(
            timestamp=datetime.now().isoformat(),
            filename=filename,
            url=download.url,
            saved_to=save_path,
            trigger_action=self.last_action.description if self.last_action else None,
        )
        self.downloads.append(dl)

    # JavaScript to inject into pages for DOM-level recording.
    # Uses window.__recordAction (exposed by Playwright) to send events directly to Python.
    _DOM_RECORDER_JS = """
    (() => {
        if (window.__webAutomatorRecording) return;
        window.__webAutomatorRecording = true;

        function bestSelector(el) {
            if (el.id) return '#' + el.id;
            // For radio/checkbox with same name, include value to distinguish
            if (el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio') && el.name) {
                return 'input[name="' + el.name + '"][value="' + el.value + '"]';
            }
            if (el.name) return el.tagName.toLowerCase() + '[name="' + el.name + '"]';
            if (el.type && el.tagName === 'INPUT')
                return 'input[type="' + el.type + '"]';
            if (el.className && typeof el.className === 'string') {
                const cls = el.className.trim().split(/\\s+/).slice(0, 2).join('.');
                if (cls) return el.tagName.toLowerCase() + '.' + cls;
            }
            return el.tagName.toLowerCase();
        }

        function send(action) {
            try {
                window.__recordAction(JSON.stringify(action));
            } catch(e) {
                console.warn('recordAction failed:', e);
            }
        }

        // change fires on blur (text/textarea) or on selection (select/checkbox/radio)
        // — gives final value, no duplicates
        document.addEventListener('change', (e) => {
            const el = e.target;
            const tag = el.tagName;
            if (tag !== 'INPUT' && tag !== 'TEXTAREA' && tag !== 'SELECT') return;

            const sel = bestSelector(el);
            const isSelect = tag === 'SELECT';
            const isCheckbox = el.type === 'checkbox' || el.type === 'radio';
            const isRadio = el.type === 'radio';
            const value = isCheckbox ? el.value : el.value;
            const checked = isCheckbox ? el.checked : null;

            send({
                timestamp: new Date().toISOString(),
                action_type: isRadio ? 'select' : (isSelect ? 'select' : (isCheckbox ? 'check' : 'fill')),
                selector: sel,
                value: value,
                checked: checked,
                description: (isCheckbox ? (el.checked ? 'Check ' : 'Uncheck ') : (isSelect ? 'Select ' : 'Fill ')) + sel + ' = ' + value.substring(0, 50)
            });
        }, true);

        // Capture submit — flush any focused input that hasn't fired change yet
        document.addEventListener('submit', (e) => {
            const form = e.target;
            const focused = document.activeElement;
            if (focused && (focused.tagName === 'INPUT' || focused.tagName === 'TEXTAREA')) {
                focused.blur();  // triggers change event for the focused field
            }
        }, true);

        document.addEventListener('click', (e) => {
            const el = e.target.closest('button, a, [role="button"], input[type="submit"], input[type="button"]');
            if (!el) return;
            if (el.tagName === 'INPUT' && ['text', 'email', 'password', 'tel', 'number', 'search', 'url'].includes(el.type)) return;

            send({
                timestamp: new Date().toISOString(),
                action_type: 'click',
                selector: bestSelector(el),
                value: el.innerText ? el.innerText.substring(0, 50).trim() : null,
                description: 'Click ' + bestSelector(el) + (el.innerText ? ' "' + el.innerText.substring(0, 30).trim() + '"' : '')
            });
        }, true);
    })();
    """

    async def _inject_dom_recorder(self, page: Page):
        """Inject DOM-level event recorder into the page."""
        try:
            await page.evaluate(self._DOM_RECORDER_JS)
            check = await page.evaluate("typeof window.__webAutomatorRecording")
            logger.info("DOM recorder injected (check=%s)", check)
        except Exception as e:
            logger.warning("DOM recorder injection failed: %s", e)

    async def _collect_dom_actions(self) -> list[CapturedAction]:
        """Collect actions captured by the DOM recorder from current page."""
        if not self._page:
            logger.warning("No page reference for DOM action collection")
            return []
        try:
            raw = await self._page.evaluate("window.__recordedActions || []")
            logger.info("Collected %d DOM actions from page", len(raw))
            actions = []
            for a in raw:
                actions.append(CapturedAction(
                    timestamp=a.get("timestamp", datetime.now().isoformat()),
                    action_type=a.get("action_type", "interaction"),
                    description=a.get("description", ""),
                    selector=a.get("selector"),
                    value=a.get("value"),
                    url=None,
                ))
            # Clear collected actions from page to avoid duplicates
            await self._page.evaluate("window.__recordedActions = []")
            return actions
        except Exception as e:
            logger.warning("Could not collect DOM actions: %s", e)
            return []

    async def _flush_dom_actions(self):
        """Flush DOM actions into self.actions before they are lost (e.g. on navigation)."""
        dom_actions = await self._collect_dom_actions()
        if dom_actions:
            self.actions.extend(dom_actions)
            logger.info("Flushed %d DOM actions before navigation", len(dom_actions))

    async def _on_dom_action(self, action_json: str):
        """Callback from browser JS — receives DOM actions directly into Python."""
        try:
            a = __import__("json").loads(action_json)
            action = CapturedAction(
                timestamp=a.get("timestamp", datetime.now().isoformat()),
                action_type=a.get("action_type", "interaction"),
                description=a.get("description", ""),
                selector=a.get("selector"),
                value=a.get("value"),
                url=None,
            )
            self.actions.append(action)
            logger.info("[DOM %s] %s", action.action_type.upper(), action.description)
        except Exception as e:
            logger.warning("Failed to parse DOM action: %s", e)

    async def start(self, page: Page):
        """Attach recording handlers to a page and navigate to the URL."""
        self._page = page
        page.on("request", self._on_request)
        page.on("download", self._on_download)

        # Expose Python callback to browser — persists across navigations
        await page.expose_function("__recordAction", self._on_dom_action)

        # Re-inject DOM recorder JS after every page load
        async def _on_load(page_ref=page):
            await asyncio.sleep(0.5)  # let page settle
            await self._inject_dom_recorder(page_ref)

        page.on("domcontentloaded", lambda _: asyncio.ensure_future(_on_load()))

        logger.info("Recording started: %s (session=%s)", self.base_url, self.session_id)

        # Navigate with retry — sometimes browser isn't ready on first try
        last_error = None
        for attempt in range(3):
            try:
                await page.goto(self.base_url, wait_until="domcontentloaded", timeout=30000)
                await asyncio.sleep(1)
                await self._inject_dom_recorder(page)
                logger.info("Page loaded and DOM recorder injected (attempt %d)", attempt + 1)
                last_error = None
                break
            except Exception as e:
                last_error = e
                logger.warning("Page load attempt %d failed: %s", attempt + 1, e)
                if attempt < 2:
                    await asyncio.sleep(2)

        if last_error:
            raise RuntimeError(f"Failed to load {self.base_url} after 3 attempts: {last_error}")

    async def async_stop(self) -> dict:
        """Stop recording and return results."""
        # Actions already collected via expose_function callback — just sort and return
        self.actions.sort(key=lambda a: a.timestamp)
        return self._build_results()

    def stop(self) -> dict:
        """Stop recording and return results (sync fallback)."""
        return self._build_results()

    def _build_results(self) -> dict:
        """Build the results dictionary."""
        logger.info(
            "Recording stopped: %d actions, %d downloads (session=%s)",
            len(self.actions), len(self.downloads), self.session_id,
        )

        summary = {
            "session_id": self.session_id,
            "base_url": self.base_url,
            "total_requests": self.request_count,
            "ignored_requests": self.ignored_count,
            "captured_actions": len(self.actions),
            "downloaded_files": [d.filename for d in self.downloads],
            "action_summary": {},
        }
        for action in self.actions:
            summary["action_summary"][action.action_type] = (
                summary["action_summary"].get(action.action_type, 0) + 1
            )

        return {
            "actions": [asdict(a) for a in self.actions],
            "downloads": [asdict(d) for d in self.downloads],
            "summary": summary,
        }
