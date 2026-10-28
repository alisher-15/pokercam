"""app.services.media_server against a stand-in HTTP server."""

import threading
import uuid
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from app.config import get_settings
from app.services import media_server

CALLS: list[tuple[str, str | None]] = []
MISSING = uuid.UUID(int=404)


class _Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        CALLS.append((self.path, self.headers.get("X-Internal-Token")))
        self.send_response(404 if str(MISSING) in self.path else 204)
        self.end_headers()

    def log_message(self, *args: object) -> None:
        pass


@pytest.fixture
def fake_media_server(monkeypatch: pytest.MonkeyPatch) -> Iterator[str]:
    server = HTTPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    monkeypatch.setenv("MEDIA_SERVER_URL", f"http://127.0.0.1:{server.server_port}")
    get_settings.cache_clear()
    CALLS.clear()
    yield
    server.shutdown()
    get_settings.cache_clear()


def test_recheck_posts_each_table_with_the_internal_token(fake_media_server: None) -> None:
    tables = [uuid.uuid4(), MISSING]  # a table without a room answers 404: nothing to apply
    assert media_server.recheck_license(tables) is True
    assert [(f"/internal/tables/{t}/license-check", "test-internal-token") for t in tables] == CALLS


def test_recheck_fails_when_media_server_is_down(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MEDIA_SERVER_URL", "http://127.0.0.1:1")
    get_settings.cache_clear()
    assert media_server.recheck_license([uuid.uuid4()]) is False
    get_settings.cache_clear()
