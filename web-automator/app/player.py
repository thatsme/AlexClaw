"""
Headless automation replay engine.

Generalized from TOS cone_downloader.py. Executes automation configs
with steps like navigate, fill, click, download, wait.
"""

import asyncio
import json
import logging
import os
import re
from datetime import datetime, timedelta
from typing import Any, Optional

from patchright.async_api import Page, BrowserContext

logger = logging.getLogger(__name__)

DOWNLOAD_DIR = os.environ.get("DOWNLOAD_DIR", "/tmp/downloads")


class Player:
    """
    Headless automation player. Executes a config-driven workflow:
    login, navigate, fill forms, click buttons, download files.
    """

    def __init__(self, config: dict[str, Any]):
        self.config = config
        self.downloads: list[str] = []
        self.screenshots: list[str] = []
        self.scraped_data: list[dict] = []
        self.output_dir = config.get("output_dir", DOWNLOAD_DIR)
        os.makedirs(self.output_dir, exist_ok=True)

    def _resolve_date(self, value: str) -> str:
        """Resolve relative date values."""
        if value == "yesterday":
            d = datetime.now() - timedelta(days=1)
        elif value == "today":
            d = datetime.now()
        else:
            return value
        return d.strftime("%d/%m/%Y")

    def _format_date_value(self, value: str, field: str) -> str:
        """Format date with time based on field type (from/to)."""
        base_date = self._resolve_date(value)
        if " " in base_date and ":" in base_date:
            return base_date
        if "from" in field.lower():
            return f"{base_date} 00:00"
        elif "to" in field.lower():
            return f"{base_date} 23:59"
        return base_date

    async def _wait_for_ready(self, page: Page, seconds: float = 2):
        """Wait for the page to settle."""
        await asyncio.sleep(seconds)
        try:
            await page.wait_for_selector(
                '[class*="loading"], [class*="spinner"]',
                state="hidden", timeout=5000
            )
        except Exception:
            pass

    async def _login(self, page: Page):
        """Execute login flow using config credentials."""
        username = self.config.get("username", "")
        password = self.config.get("password", "")
        login_config = self.config.get("login", {})

        if not username or not password:
            logger.info("No credentials in config, skipping login")
            return

        logger.info("Logging in...")
        timeout = self.config.get("page_timeout", 60) * 1000

        # Use custom selectors or auto-detect
        username_sel = login_config.get("username_selector", 'input[type="text"], input[type="email"]')
        password_sel = login_config.get("password_selector", 'input[type="password"]')
        submit_sel = login_config.get("submit_selector",
            'button[type="submit"], button:has-text("Login"), button:has-text("Sign")')

        await page.wait_for_selector("input", timeout=timeout)
        await asyncio.sleep(1)

        username_input = await page.query_selector(username_sel)
        if username_input:
            await username_input.fill(username)

        await asyncio.sleep(0.5)

        password_input = await page.query_selector(password_sel)
        if password_input:
            await password_input.fill(password)

        await asyncio.sleep(0.5)

        login_btn = await page.query_selector(submit_sel)
        if login_btn:
            await login_btn.click()

        await self._wait_for_ready(page, 3)
        logger.info("Login complete")

    async def _navigate(self, page: Page, url: str):
        """Navigate to a URL."""
        logger.info("Navigating to: %s", url)
        await page.goto(url, wait_until="domcontentloaded")
        await self._wait_for_ready(page, 3)

    async def _fill(self, page: Page, selector: str, value: str, field_type: str = "text"):
        """Fill a form field."""
        if field_type == "date":
            value = self._format_date_value(value, selector)

        logger.info("Fill %s = %s", selector, value)

        try:
            el = await page.query_selector(selector)
            if el:
                await el.click()
                await asyncio.sleep(0.3)
                await page.keyboard.press("Control+a")
                delay = 100 if field_type == "text" else 50
                await page.keyboard.type(value, delay=delay)
                await asyncio.sleep(0.5)
            else:
                logger.warning("Selector not found: %s", selector)
        except Exception as e:
            logger.warning("Fill failed for %s: %s", selector, e)

    async def _click(self, page: Page, selector: str, timeout: int = 30):
        """Click an element."""
        logger.info("Click: %s", selector)
        for attempt in range(timeout):
            try:
                el = await page.query_selector(selector)
                if el:
                    visible = await el.is_visible()
                    if visible:
                        await el.click()
                        logger.info("Clicked: %s", selector)
                        return
            except Exception:
                pass
            if attempt % 10 == 9:
                logger.info("Click attempt %d/%d for %s", attempt + 1, timeout, selector)
            await asyncio.sleep(1)

        raise RuntimeError(f"Could not click: {selector} after {timeout}s")

    async def _select(self, page: Page, selector: str, value: str):
        """Select a radio button or dropdown option."""
        logger.info("Select %s = %s", selector, value)
        try:
            el = await page.query_selector(selector)
            if el:
                tag = await el.evaluate("el => el.tagName")
                if tag == "SELECT":
                    await el.select_option(value)
                else:
                    # Radio button — just click it
                    await el.click()
                await asyncio.sleep(0.3)
            else:
                logger.warning("Selector not found: %s", selector)
        except Exception as e:
            logger.warning("Select failed for %s: %s", selector, e)

    async def _check(self, page: Page, selector: str, value: str):
        """Check or uncheck a checkbox."""
        logger.info("Check %s = %s", selector, value)
        try:
            el = await page.query_selector(selector)
            if el:
                checked = await el.is_checked()
                if not checked:
                    await el.click()
                await asyncio.sleep(0.3)
            else:
                logger.warning("Selector not found: %s", selector)
        except Exception as e:
            logger.warning("Check failed for %s: %s", selector, e)

    async def _wait_for_download(self, page: Page, trigger_selector: str, timeout: int = 120) -> str:
        """Click a download trigger and wait for the file."""
        download_path = None
        download_event = asyncio.Event()

        async def handle_download(download):
            nonlocal download_path
            filename = download.suggested_filename
            download_path = os.path.join(self.output_dir, filename)
            logger.info("Download: %s", filename)
            await download.save_as(download_path)
            download_event.set()

        page.on("download", handle_download)

        await self._click(page, trigger_selector)

        logger.info("Waiting for download...")
        try:
            await asyncio.wait_for(download_event.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            raise RuntimeError("Download timed out")

        if download_path:
            self.downloads.append(download_path)
        return download_path

    async def _extract_grid(self, page: Page, selector: str = "#jqxGrid", columns: list[str] | None = None) -> list[dict]:
        """Extract data from a jqxGrid widget using its JavaScript API.

        Uses jQuery's jqxGrid('getrows') to get all loaded data directly —
        no DOM parsing needed. Works with any jqxGrid instance.

        Args:
            selector: jQuery selector for the grid (e.g. "#jqxGrid", "#myGrid")
            columns: optional list of column keys to extract. If None, returns all columns.
        """
        logger.info("Extracting jqxGrid: %s", selector)

        extract_js = """([selector, columns]) => {
            try {
                const jq = typeof jQuery !== 'undefined' ? jQuery : (typeof $ !== 'undefined' ? $ : null);
                if (!jq) return {error: 'jQuery not available on this page'};

                const $grid = jq(selector);
                if (!$grid.length) return {error: 'Grid not found: ' + selector};
                if (!$grid.jqxGrid) return {error: 'Not a jqxGrid: ' + selector};

                const rows = $grid.jqxGrid('getrows');
                if (!rows || !rows.length) {
                    return {error: 'No rows in grid', headers: [], data: []};
                }

                // Get column names from first row or grid columns
                let allKeys;
                try {
                    const gridColumns = $grid.jqxGrid('columns');
                    allKeys = gridColumns.records.map(c => c.datafield || c.text);
                } catch(e) {
                    allKeys = Object.keys(rows[0]).filter(k =>
                        !k.startsWith('_') && !k.startsWith('$') &&
                        k !== 'uid' && k !== 'boundindex' && k !== 'uniqueid' &&
                        k !== 'visibleindex'
                    );
                }

                const keys = columns || allKeys;
                const data = rows.map(row => {
                    const obj = {};
                    for (const k of keys) {
                        obj[k] = row[k] !== undefined ? row[k] : null;
                    }
                    return obj;
                });

                return {headers: keys, data: data, total: rows.length};
            } catch(e) {
                return {error: e.toString()};
            }
        }"""

        # Try main page first
        result = await page.evaluate(extract_js, [selector, columns])

        # If not found on main page, try inside iframes
        if result.get("error") and ("not available" in result["error"] or "not found" in result["error"]):
            for i, frame in enumerate(page.frames[1:]):
                try:
                    result = await frame.evaluate(extract_js, [selector, columns])
                    if not result.get("error"):
                        logger.info("Found grid in iframe %d: %s", i, frame.url[:80])
                        break
                except Exception as e:
                    logger.debug("Could not check iframe %d: %s", i, e)

        if result.get("error"):
            logger.warning("Grid extraction error: %s", result["error"])
        else:
            data = result.get("data", [])
            logger.info("Extracted %d rows from %s", len(data), selector)

        # Save to file
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        grid_path = os.path.join(self.output_dir, f"grid_{ts}.json")
        with open(grid_path, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2, ensure_ascii=False)

        self.scraped_data.append({"type": "jqxgrid", "selector": selector, **result})
        return result

    async def _scrape(self, page: Page, selector: str = "table") -> list[dict]:
        """Extract table data from the current page and all iframes.

        Returns a list of tables, each with headers and rows:
        [{"headers": ["Col1", "Col2"], "rows": [["val1", "val2"], ...], "source": "main"}, ...]
        """
        logger.info("Scraping: %s", selector)

        extract_js = """(selector) => {
            const results = [];

            // --- Strategy 1: Standard HTML tables ---
            const tables = document.querySelectorAll(
                selector === 'table' ? 'table' : selector + ' table, table'
            );
            for (const table of tables) {
                const headers = [];
                const headerRow = table.querySelector('thead tr') || table.querySelector('tr');
                if (headerRow) {
                    for (const th of headerRow.querySelectorAll('th, td')) {
                        headers.push(th.innerText.trim());
                    }
                }
                const rows = [];
                const bodyRows = table.querySelectorAll('tbody tr');
                const rowElements = bodyRows.length > 0 ? bodyRows : table.querySelectorAll('tr');
                for (const tr of rowElements) {
                    if (tr === headerRow) continue;
                    const cells = [];
                    for (const td of tr.querySelectorAll('td, th')) {
                        cells.push(td.innerText.trim());
                    }
                    if (cells.length > 0) rows.push(cells);
                }
                if (headers.length > 0 || rows.length > 0) {
                    results.push({headers, rows, type: 'table'});
                }
            }

            // --- Strategy 2: jqxGrid / div-based grids ---
            const grids = document.querySelectorAll(
                '[role="grid"], .jqx-grid, .jqx-widget, [id*="jqxgrid"], [id*="jqxGrid"]'
            );
            for (const grid of grids) {
                const headers = [];
                // jqxGrid headers are in a separate columnsheader div
                const headerCells = grid.querySelectorAll(
                    '[role="columnheader"], .jqx-grid-column-header .jqx-grid-cell, ' +
                    '.jqx-grid-header .jqx-grid-cell'
                );
                for (const h of headerCells) {
                    const text = h.innerText.trim();
                    if (text) headers.push(text);
                }

                const rows = [];
                // jqxGrid rows
                const gridRows = grid.querySelectorAll(
                    '[role="row"], .jqx-grid-cell-wrap'
                );
                let currentRow = [];
                for (const cell of grid.querySelectorAll(
                    '[role="gridcell"], .jqx-grid-cell'
                )) {
                    // Skip header cells
                    if (cell.closest('[role="columnheader"]') ||
                        cell.closest('.jqx-grid-column-header') ||
                        cell.closest('.jqx-grid-header')) continue;

                    currentRow.push(cell.innerText.trim());
                    // Row boundary: when we have as many cells as headers
                    if (headers.length > 0 && currentRow.length >= headers.length) {
                        rows.push(currentRow);
                        currentRow = [];
                    }
                }
                if (currentRow.length > 0) rows.push(currentRow);

                if (headers.length > 0 || rows.length > 0) {
                    results.push({headers, rows, type: 'jqxgrid'});
                }
            }

            // --- Strategy 3: Generic visible tabular data ---
            // Look for repeated row-like structures with consistent column counts
            if (results.length === 0) {
                const containers = document.querySelectorAll(
                    selector !== 'table' ? selector : '[class*="table"], [class*="grid"], [class*="data"]'
                );
                for (const container of containers) {
                    const divRows = container.querySelectorAll(':scope > div, :scope > li');
                    if (divRows.length < 2) continue;

                    const rows = [];
                    let colCount = 0;
                    for (const row of divRows) {
                        const text = row.innerText.trim();
                        if (!text) continue;
                        // Split by newlines or tabs
                        const cells = text.split(/[\\t\\n]+/).map(c => c.trim()).filter(Boolean);
                        if (cells.length >= 2) {
                            if (colCount === 0) colCount = cells.length;
                            if (cells.length === colCount) rows.push(cells);
                        }
                    }
                    if (rows.length >= 2) {
                        results.push({
                            headers: rows[0],
                            rows: rows.slice(1),
                            type: 'div_grid'
                        });
                    }
                }
            }

            return results;
        }"""

        # Scrape main page
        tables = await page.evaluate(extract_js, selector)
        for t in tables:
            t["source"] = "main"

        # Scrape inside all iframes
        for i, frame in enumerate(page.frames[1:]):  # skip main frame
            try:
                frame_tables = await frame.evaluate(extract_js, selector)
                for t in frame_tables:
                    t["source"] = f"iframe_{i}_{frame.url[:80]}"
                tables.extend(frame_tables)
            except Exception as e:
                logger.debug("Could not scrape iframe %d: %s", i, e)

        logger.info("Scraped %d table(s), total %d rows",
                     len(tables), sum(len(t["rows"]) for t in tables))

        # Save to file
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        scrape_path = os.path.join(self.output_dir, f"scraped_{ts}.json")
        with open(scrape_path, "w", encoding="utf-8") as f:
            json.dump(tables, f, indent=2, ensure_ascii=False)

        self.scraped_data.extend(tables)
        return tables

    async def _take_screenshot(self, page: Page, name: str = "screenshot") -> str:
        """Take a screenshot for debugging."""
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        path = os.path.join(self.output_dir, f"{name}_{ts}.png")
        await page.screenshot(path=path)
        self.screenshots.append(path)
        return path

    async def run(self, page: Page) -> dict:
        """
        Execute the full automation from config.

        Config format:
        {
            "url": "https://example.com",
            "username": "user",          # optional
            "password": "pass",          # optional
            "login": {                   # optional custom login selectors
                "username_selector": "...",
                "password_selector": "...",
                "submit_selector": "..."
            },
            "steps": [                   # ordered interaction steps
                {"action": "navigate", "url": "https://..."},
                {"action": "fill", "selector": "input#name", "value": "test"},
                {"action": "click", "selector": "button.submit"},
                {"action": "wait", "value": "3"},
                {"action": "keyboard", "value": "Enter"},
                {"action": "download", "selector": "button.export"},
                {"action": "scrape", "selector": "table"},
                {"action": "screenshot", "value": "after_login"}
            ],
            "page_timeout": 60,
            "download_timeout": 120
        }
        """
        url = self.config.get("url", "")
        steps = self.config.get("steps", [])

        try:
            # Navigate to starting URL
            if url:
                await self._navigate(page, url)

            # Login if credentials provided
            if self.config.get("username") and self.config.get("password"):
                await self._login(page)

            # Execute steps
            for i, step in enumerate(steps):
                action = step.get("action", "")
                selector = step.get("selector", "")
                value = step.get("value", "")
                step_timeout = step.get("timeout", 30)

                logger.info("Step %d/%d: %s", i + 1, len(steps), action)

                if action == "navigate":
                    await self._navigate(page, step.get("url", value))

                elif action == "fill":
                    field_type = step.get("type", "text")
                    await self._fill(page, selector, value, field_type)

                elif action == "select":
                    # Radio button or select dropdown
                    await self._select(page, selector, value)

                elif action == "check":
                    # Checkbox — ensure it matches desired state
                    await self._check(page, selector, value)

                elif action == "click":
                    await self._click(page, selector, timeout=step_timeout)

                elif action == "download":
                    dl_timeout = step.get("timeout", self.config.get("download_timeout", 120))
                    await self._wait_for_download(page, selector, timeout=dl_timeout)

                elif action == "wait":
                    wait_seconds = float(value) if value else 2
                    await self._wait_for_ready(page, wait_seconds)

                elif action == "keyboard":
                    await page.keyboard.press(value)
                    await asyncio.sleep(0.5)

                elif action == "scrape":
                    scrape_sel = selector or "table"
                    await self._scrape(page, scrape_sel)

                elif action == "extract_grid":
                    grid_sel = selector or "#jqxGrid"
                    columns = step.get("columns")  # optional column mapping
                    await self._extract_grid(page, grid_sel, columns)

                elif action == "scrape_text":
                    # Grab visible page text (useful for non-table results)
                    text = await page.evaluate("() => document.body.innerText")
                    logger.info("Scraped text: %d chars", len(text or ""))
                    self.scraped_data.append({"type": "text", "data": text})

                elif action == "evaluate":
                    # Run arbitrary JS and capture result
                    eval_result = await page.evaluate(value)
                    if eval_result is not None:
                        self.scraped_data.append({"type": "evaluate", "data": eval_result})

                elif action == "screenshot":
                    await self._take_screenshot(page, value or f"step_{i}")

                else:
                    logger.warning("Unknown action: %s", action)

            # Final screenshot
            await self._take_screenshot(page, "final")

            return {
                "status": "success",
                "output": f"Completed {len(steps)} steps",
                "downloads": self.downloads,
                "screenshots": self.screenshots,
                "scraped_data": self.scraped_data,
            }

        except Exception as e:
            logger.error("Automation failed: %s", e)
            try:
                await self._take_screenshot(page, "error")
            except Exception:
                pass

            return {
                "status": "error",
                "output": None,
                "downloads": self.downloads,
                "screenshots": self.screenshots,
                "scraped_data": self.scraped_data,
                "error": str(e),
            }
