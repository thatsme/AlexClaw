"""Phase 2 (reports/WEB_AUTOMATOR_TARGET.md §1.1): the sidecar is not root.

The test service runs under the production container's constraints (non-root,
no capabilities, read-only root, tmpfs /tmp — pinned by
test/compose_hardening_test.exs), so these tests and the real-Chromium tests in
test_egress_browser.py together prove the browser launches as the production
container will run it.

The image as built installed the browsers under /root (mode 700), where a
non-root user cannot read them; they must live on a path given by
PLAYWRIGHT_BROWSERS_PATH, readable by the runtime user.
"""

import os
import tempfile
from pathlib import Path


def test_the_process_is_not_root():
    assert os.geteuid() != 0
    assert os.getegid() != 0


def _browser_executables():
    """Every browser the player may launch: patchright's Chromium under
    PLAYWRIGHT_BROWSERS_PATH (arm64), or Google Chrome installed system-wide
    (amd64, `channel: "chrome"`)."""
    path = os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "")
    found = [p for p in Path(path).glob("chromium*/**/chrome") if p.is_file()] if path else []
    system_chrome = Path("/opt/google/chrome/chrome")
    if system_chrome.is_file():
        found.append(system_chrome)
    return found


def test_browsers_live_on_a_readable_path_outside_root():
    path = os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "")

    assert path, "PLAYWRIGHT_BROWSERS_PATH is not set"
    assert not path.startswith("/root"), f"browsers are under {path}"
    assert os.access(path, os.R_OK | os.X_OK), f"{path} is not readable by uid {os.geteuid()}"


def test_the_browser_the_player_launches_is_executable_by_this_user():
    executables = _browser_executables()

    assert executables, "no Chromium under PLAYWRIGHT_BROWSERS_PATH and no system Chrome"
    for exe in executables:
        assert not str(exe).startswith("/root"), f"{exe} is under /root"
        assert os.access(exe, os.X_OK), f"{exe} is not executable by uid {os.geteuid()}"


def test_the_root_filesystem_is_read_only():
    for directory in ["/", "/app", "/usr", "/etc"]:
        probe = Path(directory) / ".write-probe"
        try:
            probe.write_text("x")
        except OSError:
            continue
        probe.unlink()
        raise AssertionError(f"{directory} is writable")


def test_tmp_is_writable():
    with tempfile.NamedTemporaryFile(dir="/tmp") as handle:
        handle.write(b"x")
