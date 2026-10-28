import os
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, make_url, text
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import get_engine
from app.models import Base, Brand, Client, License, PokerTable
from app.security import generate_private_key, keyed_hash, new_activation_key, normalize_activation_key, private_key

# Tests use their own database, never DATABASE_URL.
TEST_DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL", "postgresql+psycopg://pokercam:pokercam@localhost:5432/pokercam_test"
)
os.environ.update(
    DATABASE_URL=TEST_DATABASE_URL,
    JWT_PRIVATE_KEY=generate_private_key(),
    HASH_SECRET="test-hash-secret",
    INTERNAL_API_TOKEN="test-internal-token",
    ADMIN_SESSION_SECRET="test-session-secret",
    PUBLIC_API_URL="https://cam.test",
)


def _reset_caches() -> None:
    get_settings.cache_clear()
    get_engine.cache_clear()
    private_key.cache_clear()


@pytest.fixture(scope="session")
def database_url() -> Iterator[str]:
    """An empty test database migrated to the latest revision. Created on the first run."""
    _reset_caches()
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
def db(database_url: str) -> Iterator[Session]:
    """A session on the test database; every table is emptied after the test."""
    engine = create_engine(database_url)
    with Session(engine, expire_on_commit=False) as session:
        yield session
    with engine.begin() as connection:
        tables = ", ".join(f'"{name}"' for name in Base.metadata.tables)
        connection.execute(text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))
    engine.dispose()


@pytest.fixture
def client(db: Session, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    from app.admin.routes import login_limiter
    from app.api.v1 import activation_limiter, pairing_limiter

    for limiter in (login_limiter, activation_limiter, pairing_limiter):
        limiter.reset()
    _reset_caches()
    from app.main import create_app

    with TestClient(create_app()) as test_client:
        yield test_client
    get_engine().dispose()
    _reset_caches()


@dataclass
class Club:
    client: Client
    key: str
    tables: list[PokerTable]

    @property
    def table(self) -> PokerTable:
        return self.tables[0]


@pytest.fixture
def make_club(db: Session):
    """A client with its brand, license and tables; paid for a month unless told otherwise."""

    def make(
        *, paid_until: datetime | None = None, suspended: bool = False, max_tables: int = 1, tables: int = 1
    ) -> Club:
        brand = Brand(
            app_name="Test",
            android_application_id="com.example.test",
            colors={"primary": "#000000", "secondary": "#111111", "background": "#222222", "accent": "#333333"},
        )
        key = new_activation_key()
        client = Client(name="Club", brand=brand, activation_key_hash=keyed_hash(normalize_activation_key(key)))
        db.add(client)
        db.flush()
        db.add(
            License(
                client_id=client.id,
                paid_until=paid_until or datetime.now(UTC) + timedelta(days=30),
                suspended=suspended,
                max_tables=max_tables,
            )
        )
        made = [PokerTable(client_id=client.id, name=str(n), number=n) for n in range(1, tables + 1)]
        db.add_all(made)
        db.commit()
        return Club(client=client, key=key, tables=made)

    return make


def activate(api: TestClient, key: str, machine_id: str = "machine-1") -> dict[str, str]:
    response = api.post(
        "/api/v1/viewer/activate", json={"activation_key": key, "machine_id": machine_id, "name": "PC 1"}
    )
    assert response.status_code == 200, response.text
    return response.json()


def access_token(api: TestClient, refresh_token: str, table_id: object = None) -> str:
    body = {"refresh_token": refresh_token} | ({"table_id": str(table_id)} if table_id else {})
    response = api.post("/api/v1/auth/token", json=body)
    assert response.status_code == 200, response.text
    return response.json()["access_token"]


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def pair_phone(api: TestClient, viewer_access: str, table_id: object, android_id: str = "android-1") -> dict[str, str]:
    code = api.post(f"/api/v1/tables/{table_id}/pairing-code", headers=bearer(viewer_access)).json()["code"]
    response = api.post("/api/v1/device/pair", json={"code": code, "model": "Huawei P30", "android_id": android_id})
    assert response.status_code == 200, response.text
    return response.json()
