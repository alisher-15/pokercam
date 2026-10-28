import os
from collections.abc import Iterator

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, make_url, text

from app.config import get_settings
from app.db import get_engine

# Tests use their own database, never DATABASE_URL.
TEST_DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL", "postgresql+psycopg://pokercam:pokercam@localhost:5432/pokercam_test"
)


@pytest.fixture(scope="session")
def database_url() -> Iterator[str]:
    """An empty test database migrated to the latest revision. Created on the first run."""
    url = make_url(TEST_DATABASE_URL)
    server = create_engine(url.set(database="postgres"), isolation_level="AUTOCOMMIT")
    with server.connect() as connection:
        exists = connection.execute(text("SELECT 1 FROM pg_database WHERE datname = :name"), {"name": url.database})
        if exists.scalar() is None:
            connection.execute(text(f'CREATE DATABASE "{url.database}"'))
    server.dispose()
    engine = create_engine(TEST_DATABASE_URL)
    with engine.begin() as connection:
        connection.execute(text("DROP SCHEMA public CASCADE"))
        connection.execute(text("CREATE SCHEMA public"))
    engine.dispose()
    config = Config("alembic.ini")
    config.attributes["database_url"] = TEST_DATABASE_URL
    command.upgrade(config, "head")
    yield TEST_DATABASE_URL


@pytest.fixture
def client(database_url: str, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    monkeypatch.setenv("DATABASE_URL", database_url)
    get_settings.cache_clear()
    get_engine.cache_clear()
    from app.main import create_app

    with TestClient(create_app()) as test_client:
        yield test_client
    get_engine().dispose()
    get_settings.cache_clear()
    get_engine.cache_clear()
