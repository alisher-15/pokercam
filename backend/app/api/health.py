import logging
from typing import Annotated

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.db import get_session

router = APIRouter()
log = logging.getLogger(__name__)


@router.get("/health")
def health(response: Response, session: Annotated[Session, Depends(get_session)]) -> dict[str, str]:
    """Liveness for docker compose and monitoring: 503 while the database is unreachable."""
    try:
        session.execute(text("SELECT 1"))
    except SQLAlchemyError:
        log.warning("health check: database unreachable", exc_info=True)
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "error", "database": "unreachable"}
    return {"status": "ok", "database": "ok"}
