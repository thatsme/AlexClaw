"""0.4.0 S7 (V040_SECURITY_DESIGN.md §6): the shared token is a bootstrap
file, not an environment variable.

A one-shot service generates it into a volume that only AlexClaw and the
sidecar mount, read-only. The sidecar reads the file named by
WEB_AUTOMATOR_TOKEN_FILE at request time (a regenerated token takes effect
without a restart), strips the trailing newline, and fails closed: no file, an
unreadable one or an empty one refuses every protected route (503). The old
WEB_AUTOMATOR_TOKEN variable is not read at all.
"""

from fastapi.testclient import TestClient

from app.main import app

TOKEN = "file-token-0123456789"


def status(headers=None):
    return TestClient(app).get("/status", headers=headers or {}).status_code


def test_the_token_comes_from_the_file(monkeypatch, tmp_path):
    path = tmp_path / "token"
    path.write_text(TOKEN + "\n")
    monkeypatch.setenv("WEB_AUTOMATOR_TOKEN_FILE", str(path))

    assert status({"Authorization": f"Bearer {TOKEN}"}) == 200
    assert status({"Authorization": "Bearer not-the-token"}) == 401


def test_the_file_is_read_at_request_time(monkeypatch, tmp_path):
    path = tmp_path / "token"
    path.write_text(TOKEN)
    monkeypatch.setenv("WEB_AUTOMATOR_TOKEN_FILE", str(path))
    assert status({"Authorization": f"Bearer {TOKEN}"}) == 200

    path.write_text("a-new-token-9876543210")
    assert status({"Authorization": f"Bearer {TOKEN}"}) == 401
    assert status({"Authorization": "Bearer a-new-token-9876543210"}) == 200


def test_a_missing_file_refuses_everything(monkeypatch, tmp_path):
    monkeypatch.setenv("WEB_AUTOMATOR_TOKEN_FILE", str(tmp_path / "absent"))
    assert status({"Authorization": f"Bearer {TOKEN}"}) == 503


def test_an_empty_file_refuses_everything(monkeypatch, tmp_path):
    path = tmp_path / "token"
    path.write_text("\n")
    monkeypatch.setenv("WEB_AUTOMATOR_TOKEN_FILE", str(path))
    assert status({"Authorization": "Bearer "}) == 503


def test_the_old_variable_is_not_read(monkeypatch, tmp_path):
    monkeypatch.setenv("WEB_AUTOMATOR_TOKEN", TOKEN)
    monkeypatch.setenv("WEB_AUTOMATOR_TOKEN_FILE", str(tmp_path / "absent"))
    assert status({"Authorization": f"Bearer {TOKEN}"}) == 503
