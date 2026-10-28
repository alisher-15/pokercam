import base64

import pytest
from pydantic import ValidationError
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.cli import DEMO_CLIENT, create_admin, gen_keys, seed
from app.config import Settings, get_settings
from app.models import AdminUser, Client, License, PokerTable
from app.security import verify_password


def test_gen_keys_prints_env_lines(capsys: pytest.CaptureFixture[str]) -> None:
    gen_keys()
    lines = dict(line.split("=", 1) for line in capsys.readouterr().out.splitlines())
    assert set(lines) == {"JWT_PRIVATE_KEY", "HASH_SECRET", "INTERNAL_API_TOKEN", "ADMIN_SESSION_SECRET"}
    assert len(base64.b64decode(lines["JWT_PRIVATE_KEY"])) == 32


def test_create_admin_then_change_password(db: Session) -> None:
    assert create_admin(db, "Boss@Example.com", "first-password") is True
    assert create_admin(db, "boss@example.com", "second-password") is False
    admin = db.scalar(select(AdminUser))
    assert admin.email == "boss@example.com"
    assert verify_password(admin.password_hash, "second-password")


def test_seed_is_idempotent(db: Session, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ADMIN_EMAIL", "seed@example.com")
    monkeypatch.setenv("ADMIN_PASSWORD", "seed-password")
    get_settings.cache_clear()
    key = seed(db)
    db.commit()
    assert key is not None
    assert seed(db) is None
    client = db.scalar(select(Client).where(Client.name == DEMO_CLIENT))
    assert db.scalar(select(License.max_tables).where(License.client_id == client.id)) == 1
    assert db.scalar(select(func.count()).where(PokerTable.client_id == client.id)) == 1
    assert db.scalar(select(AdminUser.email)) == "seed@example.com"
    get_settings.cache_clear()


def test_production_refuses_development_secrets() -> None:
    with pytest.raises(ValidationError, match="JWT_PRIVATE_KEY, HASH_SECRET, INTERNAL_API_TOKEN, ADMIN_SESSION_SECRET"):
        Settings(
            _env_file=None,
            environment="production",
            jwt_private_key="",
            hash_secret="",
            internal_api_token="",
            admin_session_secret="",
        )


def test_production_starts_with_real_secrets() -> None:
    settings = Settings(
        _env_file=None,
        environment="production",
        jwt_private_key="a2V5",
        hash_secret="h",
        internal_api_token="i",
        admin_session_secret="s",
    )
    assert settings.environment == "production"


def test_empty_secrets_fall_back_to_development_defaults() -> None:
    settings = Settings(_env_file=None, hash_secret="", internal_api_token="")
    assert settings.hash_secret and settings.internal_api_token
