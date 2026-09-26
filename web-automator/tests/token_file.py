"""The shared token as the sidecar gets it since 0.4.0: a file named by
WEB_AUTOMATOR_TOKEN_FILE (see test_token_file.py)."""

import tempfile


def use_token(monkeypatch, token):
    """Point WEB_AUTOMATOR_TOKEN_FILE at a fresh file holding `token`."""
    with tempfile.NamedTemporaryFile("w", suffix=".token", delete=False) as handle:
        handle.write(token)
    monkeypatch.setenv("WEB_AUTOMATOR_TOKEN_FILE", handle.name)
