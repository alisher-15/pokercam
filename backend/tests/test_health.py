import pytest
from fastapi.testclient import TestClient

from app.config import get_settings
from app.db import get_engine


def test_health_ok(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "database": "ok"}


def test_health_reports_unreachable_database(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql+psycopg://nobody:nothing@127.0.0.1:1/none")
    get_settings.cache_clear()
    get_engine.cache_clear()
    response = client.get("/health")
    assert response.status_code == 503
    assert response.json() == {"status": "error", "database": "unreachable"}
