import secrets

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from app.admin import routes as admin
from app.api import errors, health, internal, v1
from app.config import get_settings
from app.log import configure_logging


def create_app() -> FastAPI:
    settings = get_settings()
    configure_logging(settings.log_level)
    app = FastAPI(title="Backend API", version="0.1.0")
    errors.install(app)
    app.include_router(health.router)
    app.include_router(v1.router)
    app.include_router(internal.router)
    app.include_router(admin.router)
    admin.install(app)
    app.mount("/admin/static", StaticFiles(directory=admin.STATIC_DIR), name="admin-static")
    # Development without ADMIN_SESSION_SECRET: admins sign in again after every restart.
    app.add_middleware(
        SessionMiddleware,
        secret_key=settings.admin_session_secret or secrets.token_urlsafe(32),
        session_cookie="admin_session",
        max_age=12 * 3600,
        same_site="strict",
        https_only=settings.environment == "production",
    )
    return app


app = create_app()
