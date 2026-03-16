#!/usr/bin/env python3
"""
Web Automator — Desktop Recorder

Launches your real Chrome (via --remote-debugging-port) with zero automation
flags, then connects via CDP to passively observe network traffic.
PerimeterX / HUMAN / Cloudflare cannot detect this — it's a normal browser.

Usage:
    python recorder_desktop.py
    python recorder_desktop.py --url https://example.com
    python recorder_desktop.py --url https://example.com --output my_recording.json

Build standalone:
    pip install pyinstaller
    pyinstaller --onefile --name recorder recorder_desktop.py
"""

import asyncio
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
from dataclasses import dataclass, asdict
from datetime import datetime
from typing import Optional
from urllib.parse import urlparse

try:
    from patchright.async_api import async_playwright, Request
except ImportError:
    print("Patchright not installed!")
    print("  pip install patchright")
    print("  python -m patchright install chrome")
    sys.exit(1)


# --- Data classes ---

@dataclass
class CapturedAction:
    timestamp: str
    action_type: str
    description: str
    selector: Optional[str] = None
    value: Optional[str] = None
    url: Optional[str] = None
    post_data: Optional[str] = None
    headers: Optional[dict] = None


@dataclass
class DownloadedFile:
    timestamp: str
    filename: str
    url: str
    saved_to: str
    trigger_action: Optional[str] = None


# --- Chrome finder ---

def find_chrome() -> str:
    """Find Chrome executable on the system."""
    if sys.platform == "win32":
        candidates = [
            os.path.expandvars(r"%ProgramFiles%\Google\Chrome\Application\chrome.exe"),
            os.path.expandvars(r"%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"),
            os.path.expandvars(r"%LocalAppData%\Google\Chrome\Application\chrome.exe"),
        ]
    elif sys.platform == "darwin":
        candidates = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
    else:
        candidates = ["/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium"]

    for path in candidates:
        if os.path.isfile(path):
            return path

    # Try PATH
    chrome = shutil.which("chrome") or shutil.which("google-chrome") or shutil.which("google-chrome-stable")
    if chrome:
        return chrome

    print("ERROR: Chrome not found! Install Google Chrome.")
    sys.exit(1)


def find_free_port() -> int:
    """Find a free TCP port for Chrome debugging."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# --- Recorder ---

IGNORE_EXTENSIONS = frozenset([
    ".svg", ".png", ".jpg", ".jpeg", ".gif", ".webp",
    ".css", ".js", ".woff", ".woff2", ".ttf", ".ico", ".map",
])

IGNORE_PATHS = frozenset(["/pong", "/heartbeat", "/health", "/ping"])

DEFAULT_PATTERNS = [
    "download", "export", "filter", "button",
    "login", "menu", "submit", "search", "report",
]


class DesktopRecorder:
    def __init__(self, base_url: str, output_file: str, patterns: list[str] | None = None):
        self.base_url = base_url
        self.output_file = output_file
        self.patterns = patterns or DEFAULT_PATTERNS

        self.actions: list[CapturedAction] = []
        self.downloads: list[DownloadedFile] = []
        self.request_count = 0
        self.ignored_count = 0
        self.last_action: Optional[CapturedAction] = None

    def _is_interesting(self, request: Request) -> bool:
        url = request.url
        path = urlparse(url).path

        if any(path.endswith(ext) for ext in IGNORE_EXTENSIONS):
            self.ignored_count += 1
            return False

        if path.lower() in IGNORE_PATHS:
            self.ignored_count += 1
            return False

        if request.method == "POST":
            post_data = request.post_data or ""
            combined = (path + post_data).lower()
            for key, val in request.headers.items():
                if key.startswith("x-") and val:
                    combined += val.lower()
            if any(p in combined for p in self.patterns):
                return True
            if post_data and len(post_data) > 2:
                return True
            self.ignored_count += 1
            return False

        if request.resource_type in ("document", "xhr", "fetch"):
            return True

        self.ignored_count += 1
        return False

    def _classify(self, request: Request) -> CapturedAction:
        url = request.url
        path = urlparse(url).path
        post_data = request.post_data
        method = request.method
        combined = (path + (post_data or "")).lower()

        action_type = "interaction"
        description = f"{method} {path}"

        if "login" in combined or "auth" in combined or "signin" in combined:
            action_type = "login"
            description = "Login/authentication"
        elif any(kw in combined for kw in ["download", "export", "excel", "csv", "pdf"]):
            action_type = "download_click"
            description = "Download triggered"
        elif "filter" in combined or "search" in combined or "query" in combined:
            action_type = "filter"
            description = f"Filter/search: {path}"
        elif request.resource_type == "document":
            action_type = "navigate"
            description = f"Navigate to {path}"
        elif method == "POST":
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
        self.request_count += 1
        if not self._is_interesting(request):
            return
        action = self._classify(request)
        self.actions.append(action)
        self.last_action = action

        icon = {
            "login": "LOGIN",
            "download_click": "DOWNLOAD",
            "filter": "FILTER",
            "navigate": "NAV",
            "submit": "SUBMIT",
        }.get(action.action_type, "ACTION")

        print(f"  [{icon}] {action.description}")

    async def _on_download(self, download):
        filename = download.suggested_filename
        save_dir = os.path.join(os.path.dirname(self.output_file) or ".", "downloads")
        os.makedirs(save_dir, exist_ok=True)
        save_path = os.path.join(save_dir, filename)

        print(f"\n  >>> DOWNLOAD: {filename}")
        await download.save_as(save_path)

        self.downloads.append(DownloadedFile(
            timestamp=datetime.now().isoformat(),
            filename=filename,
            url=download.url,
            saved_to=save_path,
            trigger_action=self.last_action.description if self.last_action else None,
        ))

    def _save(self):
        result = {
            "base_url": self.base_url,
            "recorded_at": datetime.now().isoformat(),
            "actions": [asdict(a) for a in self.actions],
            "downloads": [asdict(d) for d in self.downloads],
            "summary": {
                "total_requests": self.request_count,
                "ignored_requests": self.ignored_count,
                "captured_actions": len(self.actions),
                "downloaded_files": [d.filename for d in self.downloads],
            },
        }

        with open(self.output_file, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2, ensure_ascii=False)

        print(f"\n  Saved to: {self.output_file}")

    async def run(self):
        chrome_path = find_chrome()
        debug_port = find_free_port()
        user_data_dir = tempfile.mkdtemp(prefix="recorder_chrome_")

        print(f"""
+==========================================+
|       Web Automator - Recorder           |
+==========================================+
|  URL: {self.base_url[:36]:<36s} |
|  Output: {self.output_file[:33]:<33s} |
|  Chrome: {os.path.basename(chrome_path):<33s} |
|  Debug port: {debug_port:<29d} |
+==========================================+

  Launching Chrome (clean profile, no automation flags)...
""")

        # Launch Chrome as a NORMAL process — no Playwright, no automation flags
        chrome_proc = subprocess.Popen(
            [
                chrome_path,
                f"--remote-debugging-port={debug_port}",
                f"--user-data-dir={user_data_dir}",
                "--no-first-run",
                "--no-default-browser-check",
                f"--window-size=1366,768",
                self.base_url,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        # Wait for Chrome to start accepting debug connections
        print("  Waiting for Chrome to start...")
        for attempt in range(30):
            try:
                with socket.create_connection(("127.0.0.1", debug_port), timeout=1):
                    break
            except (ConnectionRefusedError, OSError):
                await asyncio.sleep(0.5)
        else:
            print("  ERROR: Chrome didn't start. Is Chrome already running?")
            print("  TIP: Close all Chrome windows first, or the debug port won't work.")
            chrome_proc.terminate()
            shutil.rmtree(user_data_dir, ignore_errors=True)
            return

        print("  Chrome is running. Connecting observer...\n")

        try:
            async with async_playwright() as p:
                # Connect to the running Chrome via CDP — passive observation only
                browser = await p.chromium.connect_over_cdp(
                    f"http://127.0.0.1:{debug_port}"
                )

                # Get the existing page (Chrome already opened the URL)
                contexts = browser.contexts
                if contexts and contexts[0].pages:
                    page = contexts[0].pages[0]
                else:
                    # Fallback: open new page
                    context = contexts[0] if contexts else await browser.new_context()
                    page = await context.new_page()
                    await page.goto(self.base_url, wait_until="domcontentloaded", timeout=120000)

                # Attach passive listeners
                page.on("request", self._on_request)
                page.on("download", self._on_download)

                # Also listen on any new pages/tabs
                for ctx in browser.contexts:
                    ctx.on("page", lambda new_page: self._attach_page(new_page))

                print("""
+==========================================+
|  Chrome is open - do your thing:         |
|                                          |
|  1. Pass any CAPTCHAs (you're human!)    |
|  2. Login if needed                      |
|  3. Navigate, click, fill forms          |
|  4. Download files                       |
|                                          |
|  Press ENTER here when done              |
+==========================================+
""")
                try:
                    await asyncio.get_event_loop().run_in_executor(None, input, "")
                except (KeyboardInterrupt, asyncio.CancelledError):
                    print("\n  Interrupted - saving...")

                # Export cookies for potential headless replay
                try:
                    cookies = await contexts[0].cookies() if contexts else []
                    if cookies:
                        cookie_file = self.output_file.replace(".json", "_cookies.json")
                        with open(cookie_file, "w", encoding="utf-8") as f:
                            json.dump(cookies, f, indent=2)
                        print(f"  Cookies saved: {cookie_file} ({len(cookies)} cookies)")
                except Exception as e:
                    print(f"  Cookie export skipped: {e}")

                browser.close()

        except Exception as e:
            print(f"\n  Error: {e}")
        finally:
            # Kill Chrome
            try:
                chrome_proc.terminate()
                chrome_proc.wait(timeout=5)
            except Exception:
                chrome_proc.kill()

            # Clean up temp profile
            shutil.rmtree(user_data_dir, ignore_errors=True)

            self._save()

            print(f"""
+==========================================+
|  Recording complete                      |
|                                          |
|  Requests: {self.request_count:<5d}  Ignored: {self.ignored_count:<5d}     |
|  Actions:  {len(self.actions):<5d}  Downloads: {len(self.downloads):<5d}   |
+==========================================+
""")

    def _attach_page(self, page):
        """Attach listeners to a newly opened tab."""
        page.on("request", self._on_request)
        page.on("download", self._on_download)


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Web Automator - Desktop Recorder")
    parser.add_argument("--url", "-u", help="URL to record (or enter interactively)")
    parser.add_argument("--output", "-o", help="Output JSON file (default: recording_<timestamp>.json)")
    parser.add_argument("--patterns", "-p", nargs="*", help="Interesting URL patterns to capture")
    args = parser.parse_args()

    url = args.url
    if not url:
        print("\n  Web Automator - Desktop Recorder\n")
        url = input("  Enter URL: ").strip()
        if not url:
            print("  No URL provided.")
            sys.exit(1)

    if not url.startswith("http"):
        url = "https://" + url

    output = args.output or f"recording_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"

    recorder = DesktopRecorder(
        base_url=url,
        output_file=output,
        patterns=args.patterns,
    )
    asyncio.run(recorder.run())


if __name__ == "__main__":
    main()
