import secrets
from urllib.parse import urlsplit

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from app.admin import routes as admin
from app.api import errors, health, internal, v1
from app.config import get_settings
from app.log import configure_logging


def media_origin(media_url: str) -> str:
    """The browser viewer's origin: media-server serves it, so ws://host:3000/ws gives http://host:3000."""
    parts = urlsplit(media_url)
    return f"{'https' if parts.scheme == 'wss' else 'http'}://{parts.netloc}"


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
        # Secure only when the panel is reached over HTTPS: a browser drops a Secure cookie that came over plain
        # HTTP, and nobody could sign in to a server still on http://IP (the pilot until stage 9's Caddy).
        https_only=settings.environment == "production" and settings.public_api_url.startswith("https://"),
    )
    # Only the browser viewer on media-server's address may call the API from a page (it signs in with a key).
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[media_origin(settings.public_media_url)],
        allow_methods=["GET", "POST"],
        allow_headers=["Authorization", "Content-Type"],
    )
    return app


app = create_app()
