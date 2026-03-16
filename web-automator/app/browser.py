"""Browser lifecycle management — launch, close, contexts with stealth + fingerprint rotation."""

import logging
import os
import platform
import random
from typing import Optional

from patchright.async_api import async_playwright, Browser, BrowserContext, Playwright
from playwright_stealth import Stealth

logger = logging.getLogger(__name__)

# --- Fingerprint pools ---

_USER_AGENTS = [
    # Chrome 124 — Windows
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    # Chrome 124 — macOS
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    # Chrome 123 — Windows
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
    # Chrome 123 — macOS
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
    # Chrome 122 — Windows
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    # Edge 124 — Windows
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0",
    # Chrome 124 — Linux
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
]

_VIEWPORTS = [
    {"width": 1920, "height": 1080},
    {"width": 1366, "height": 768},
    {"width": 1536, "height": 864},
    {"width": 1440, "height": 900},
    {"width": 1680, "height": 1050},
    {"width": 2560, "height": 1440},
    {"width": 1280, "height": 720},
]

_LOCALES = ["en-US", "en-GB", "en-CA", "en-AU"]

_TIMEZONES = [
    "America/New_York",
    "America/Chicago",
    "America/Los_Angeles",
    "America/Denver",
    "Europe/London",
    "Europe/Berlin",
    "Europe/Rome",
]

_WEBGL_VENDORS = [
    "Google Inc. (NVIDIA)",
    "Google Inc. (AMD)",
    "Google Inc. (Intel)",
]

_WEBGL_RENDERERS = [
    "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)",
    "ANGLE (NVIDIA, NVIDIA GeForce GTX 1660 SUPER Direct3D11 vs_5_0 ps_5_0, D3D11)",
    "ANGLE (AMD, AMD Radeon RX 580 Direct3D11 vs_5_0 ps_5_0, D3D11)",
    "ANGLE (Intel, Intel(R) UHD Graphics 630 Direct3D11 vs_5_0 ps_5_0, D3D11)",
    "ANGLE (NVIDIA, NVIDIA GeForce RTX 4070 Direct3D11 vs_5_0 ps_5_0, D3D11)",
    "ANGLE (AMD, AMD Radeon RX 6700 XT Direct3D11 vs_5_0 ps_5_0, D3D11)",
]

_PLATFORMS = [
    "Win32",
    "MacIntel",
]


def _random_fingerprint() -> dict:
    """Generate a random but consistent browser fingerprint."""
    ua = random.choice(_USER_AGENTS)
    nav_platform = "Win32" if "Windows" in ua else ("MacIntel" if "Mac" in ua else "Linux x86_64")
    locale = random.choice(_LOCALES)

    return {
        "user_agent": ua,
        "viewport": random.choice(_VIEWPORTS),
        "locale": locale,
        "timezone_id": random.choice(_TIMEZONES),
        "webgl_vendor": random.choice(_WEBGL_VENDORS),
        "webgl_renderer": random.choice(_WEBGL_RENDERERS),
        "color_depth": random.choice([24, 32]),
        "device_scale_factor": random.choice([1, 1.25, 1.5, 2]),
        "hardware_concurrency": random.choice([4, 8, 12, 16]),
        "platform": nav_platform,
        "languages": (locale, locale.split("-")[0]),
    }


# Extra fingerprint JS that playwright-stealth doesn't cover
_EXTRA_STEALTH_JS = """
// Canvas fingerprint noise
(function() {{
    const origToDataURL = HTMLCanvasElement.prototype.toDataURL;
    HTMLCanvasElement.prototype.toDataURL = function(type) {{
        if (this.width > 16 && this.height > 16) {{
            const ctx = this.getContext('2d');
            if (ctx) {{
                const s = ctx.fillStyle;
                ctx.fillStyle = 'rgba({r},{g},{b},0.01)';
                ctx.fillRect(0, 0, 1, 1);
                ctx.fillStyle = s;
            }}
        }}
        return origToDataURL.apply(this, arguments);
    }};
}})();

// Screen properties
Object.defineProperty(screen, 'colorDepth', {{ get: () => {color_depth} }});
Object.defineProperty(screen, 'pixelDepth', {{ get: () => {color_depth} }});

// Realistic connection API
Object.defineProperty(navigator, 'connection', {{
    get: () => ({{
        effectiveType: '4g',
        rtt: {rtt},
        downlink: {downlink},
        saveData: false
    }})
}});

// Battery API — return a realistic mock
if (!navigator.getBattery) {{
    navigator.getBattery = () => Promise.resolve({{
        charging: true,
        chargingTime: Infinity,
        dischargingTime: Infinity,
        level: 1.0,
        addEventListener: () => {{}},
        removeEventListener: () => {{}}
    }});
}}

// Realistic permission query responses
const origQuery = Permissions.prototype.query;
Permissions.prototype.query = function(params) {{
    const granted = ['geolocation', 'notifications', 'push', 'midi', 'camera', 'microphone'];
    if (granted.includes(params.name)) {{
        return Promise.resolve({{ state: 'prompt', onchange: null }});
    }}
    return origQuery.apply(this, arguments);
}};
"""


class BrowserManager:
    """Manages Playwright browser instances with stealth and fingerprint rotation."""

    def __init__(self):
        self._playwright: Optional[Playwright] = None
        self._browser: Optional[Browser] = None
        self._fingerprint: Optional[dict] = None
        self._stealth: Optional[Stealth] = None

    async def launch(self, headless: bool = True) -> Browser:
        """Launch Chromium browser with anti-detection flags."""
        if self._browser and self._browser.is_connected():
            return self._browser

        self._fingerprint = _random_fingerprint()
        fp = self._fingerprint
        logger.info(
            "Fingerprint: ua=%s, viewport=%s, tz=%s, platform=%s",
            fp["user_agent"][:50] + "...",
            fp["viewport"],
            fp["timezone_id"],
            fp["platform"],
        )

        # Build stealth config — disable evasions that patchright already handles
        # or that cause visual artifacts (navigator_plugins renders "word word" text)
        self._stealth = Stealth(
            navigator_plugins=False,       # causes "word word word" text leak
            navigator_webdriver=False,     # patchright handles this
            chrome_runtime=False,          # patchright handles this
            navigator_user_agent_override=fp["user_agent"],
            navigator_platform_override=fp["platform"],
            navigator_languages_override=fp["languages"],
            webgl_vendor_override=fp["webgl_vendor"],
            webgl_renderer_override=fp["webgl_renderer"],
        )

        self._playwright = await async_playwright().start()

        # Use real Chrome on amd64, Chromium on arm64 (no Chrome for Testing ARM64 Linux builds)
        is_arm = platform.machine() in ("aarch64", "arm64")
        launch_kwargs = {} if is_arm else {"channel": "chrome"}

        self._browser = await self._playwright.chromium.launch(
            **launch_kwargs,
            headless=headless,
            args=[
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-blink-features=AutomationControlled",
                "--disable-infobars",
                f"--window-size={fp['viewport']['width']},{fp['viewport']['height']}",
            ],
        )
        logger.info("Browser launched (headless=%s, stealth=on)", headless)
        return self._browser

    async def new_context(
        self,
        accept_downloads: bool = True,
        viewport_override: dict | None = None,
        force_scale_factor: float | None = None,
    ) -> BrowserContext:
        """Create a new browser context with randomized fingerprint + stealth."""
        if not self._browser or not self._browser.is_connected():
            raise RuntimeError("Browser not launched. Call launch() first.")

        download_dir = os.environ.get("DOWNLOAD_DIR", "/tmp/downloads")
        os.makedirs(download_dir, exist_ok=True)

        fp = self._fingerprint or _random_fingerprint()

        context = await self._browser.new_context(
            viewport=viewport_override or fp["viewport"],
            user_agent=fp["user_agent"],
            locale=fp["locale"],
            timezone_id=fp["timezone_id"],
            device_scale_factor=force_scale_factor or fp["device_scale_factor"],
            accept_downloads=accept_downloads,
        )

        # Apply playwright-stealth to the context (covers all pages)
        if self._stealth:
            await self._stealth.apply_stealth_async(context)

        # Extra fingerprint hardening not covered by playwright-stealth
        extra_js = _EXTRA_STEALTH_JS.format(
            r=random.randint(0, 3),
            g=random.randint(0, 3),
            b=random.randint(0, 3),
            color_depth=fp["color_depth"],
            rtt=random.choice([50, 100, 150]),
            downlink=round(random.uniform(1.5, 10.0), 1),
        )
        await context.add_init_script(extra_js)

        return context

    async def close(self):
        """Close browser and playwright."""
        if self._browser:
            try:
                await self._browser.close()
            except Exception:
                pass
            self._browser = None

        if self._playwright:
            try:
                await self._playwright.stop()
            except Exception:
                pass
            self._playwright = None

        self._fingerprint = None
        self._stealth = None
        logger.info("Browser closed")

    @property
    def is_running(self) -> bool:
        return self._browser is not None and self._browser.is_connected()


# Singleton
browser_manager = BrowserManager()
