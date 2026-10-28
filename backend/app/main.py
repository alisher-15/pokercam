from fastapi import FastAPI

from app.api import health
from app.config import get_settings
from app.log import configure_logging


def create_app() -> FastAPI:
    configure_logging(get_settings().log_level)
    app = FastAPI(title="Backend API", version="0.0.0")
    app.include_router(health.router)
    return app


app = create_app()
