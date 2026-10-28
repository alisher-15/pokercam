from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Backend settings, read from the environment (see .env.example in the repository root)."""

    model_config = SettingsConfigDict(env_file=("../.env", ".env"), extra="ignore")

    database_url: str = "postgresql+psycopg://pokercam:pokercam@localhost:5432/pokercam"
    log_level: str = "INFO"


@lru_cache
def get_settings() -> Settings:
    return Settings()
