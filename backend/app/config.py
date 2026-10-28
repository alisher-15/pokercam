from functools import lru_cache
from typing import Literal, Self

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# Development defaults; production refuses to start with them.
DEV_HASH_SECRET = "dev-only-hash-secret"
DEV_INTERNAL_API_TOKEN = "dev-only-internal-api-token"


class Settings(BaseSettings):
    """Backend settings, read from the environment (see .env.example in the repository root)."""

    model_config = SettingsConfigDict(env_file=("../.env", ".env"), extra="ignore")

    environment: Literal["development", "production"] = "development"
    database_url: str = "postgresql+psycopg://pokercam:pokercam@localhost:5432/pokercam"
    log_level: str = "INFO"
    # Admin pages show dates and take them in this zone.
    timezone: str = "UTC"
    # Address the camera app reaches the backend at; it goes into the pairing QR code.
    public_api_url: str = "http://localhost:8000"

    # Ed25519 private key, base64 of its 32 raw bytes (python -m app.cli gen-keys).
    # Development without it: a new key at every start.
    jwt_private_key: str = ""
    # SPEC 9.1: 12 h, refreshed hourly; how long a client has access is the license's business.
    access_token_ttl: int = 12 * 3600
    # HMAC key for activation keys, pairing codes and device ids. Changing it voids every activation key.
    hash_secret: str = DEV_HASH_SECRET
    # media-server sends it to /api/v1/internal/*, the backend sends it to media-server's /internal/*.
    internal_api_token: str = DEV_INTERNAL_API_TOKEN
    # Where the backend reaches media-server («Применить сейчас» in the admin panel).
    media_server_url: str = "http://localhost:3000"
    # Signs the admin session cookie. Development without it: a new one at every start.
    admin_session_secret: str = ""
    # First admin, created by `python -m app.cli seed`.
    admin_email: str = ""
    admin_password: str = ""

    @model_validator(mode="after")
    def _production_has_secrets(self) -> Self:
        # docker compose passes unset variables as empty strings.
        self.hash_secret = self.hash_secret or DEV_HASH_SECRET
        self.internal_api_token = self.internal_api_token or DEV_INTERNAL_API_TOKEN
        if self.environment != "production":
            return self
        missing = [
            name
            for name, unset in (
                ("JWT_PRIVATE_KEY", not self.jwt_private_key),
                ("HASH_SECRET", self.hash_secret == DEV_HASH_SECRET),
                ("INTERNAL_API_TOKEN", self.internal_api_token == DEV_INTERNAL_API_TOKEN),
                ("ADMIN_SESSION_SECRET", not self.admin_session_secret),
            )
            if unset
        ]
        if missing:
            raise ValueError(f"production needs {', '.join(missing)}: python -m app.cli gen-keys")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
