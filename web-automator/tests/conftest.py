"""Shared pytest configuration for the web-automator tests."""


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "browser: launches a real headless Chromium (seconds, not milliseconds); "
        "runs in make test-python",
    )
