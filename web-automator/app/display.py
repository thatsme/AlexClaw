"""Xvfb + noVNC display management for recording mode."""

import os
import subprocess
import signal
import logging

logger = logging.getLogger(__name__)

DISPLAY = os.environ.get("DISPLAY", ":99")
NOVNC_PORT = int(os.environ.get("NOVNC_PORT", "6080"))


class DisplayManager:
    """Manages virtual display for headed browser sessions inside Docker."""

    def __init__(self):
        self._xvfb_proc = None
        self._vnc_proc = None
        self._novnc_proc = None

    @property
    def display(self) -> str:
        return DISPLAY

    @property
    def novnc_url(self) -> str:
        scheme = os.environ.get("NOVNC_SCHEME", "http")
        host = os.environ.get("NOVNC_HOST", "localhost")
        return f"{scheme}://{host}:{NOVNC_PORT}/vnc.html?autoconnect=true"

    def is_display_available(self) -> bool:
        """Check if Xvfb display is already running (managed by supervisord)."""
        try:
            result = subprocess.run(
                ["xdpyinfo", "-display", DISPLAY],
                capture_output=True, timeout=3
            )
            return result.returncode == 0
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return False

    def start(self):
        """Start Xvfb and VNC if not already running via supervisord."""
        if self.is_display_available():
            logger.info("Display %s already available (managed by supervisord)", DISPLAY)
            return

        logger.info("Starting Xvfb on display %s", DISPLAY)
        self._xvfb_proc = subprocess.Popen(
            ["Xvfb", DISPLAY, "-screen", "0", "1920x1080x24", "-ac"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )

        os.environ["DISPLAY"] = DISPLAY

    def stop(self):
        """Stop display processes if we started them."""
        for proc in [self._novnc_proc, self._vnc_proc, self._xvfb_proc]:
            if proc and proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()

        self._xvfb_proc = None
        self._vnc_proc = None
        self._novnc_proc = None


# Singleton
display_manager = DisplayManager()
