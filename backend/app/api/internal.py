"""Routes for media-server only. Guarded by INTERNAL_API_TOKEN, so they stay closed even if the port is public."""

import hmac
import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Header
from sqlalchemy import select

from app.api.deps import SessionDep
from app.api.errors import ERRORS, ApiException
from app.config import get_settings
from app.contracts.rest.internal_jwt_key_response import InternalJwtKeyResponse
from app.contracts.rest.internal_license_response import InternalLicenseResponse
from app.models import License, PokerTable
from app.security import public_key_pem
from app.services import licenses


def _internal_only(x_internal_token: Annotated[str | None, Header()] = None) -> None:
    expected = get_settings().internal_api_token
    if x_internal_token is None or not hmac.compare_digest(x_internal_token, expected):
        raise ApiException(401, "unauthorized", "X-Internal-Token required")


router = APIRouter(prefix="/api/v1/internal", responses=ERRORS, dependencies=[Depends(_internal_only)])


@router.get("/tables/{table_id}/license")
def table_license(table_id: uuid.UUID, session: SessionDep) -> InternalLicenseResponse:
    """media-server asks this when a room starts and every 10 minutes (SPEC 7.1)."""
    table = session.get(PokerTable, table_id)
    if table is None:
        raise ApiException(404, "table_not_found", "No such table")
    license_ = session.scalars(select(License).where(License.client_id == table.client_id)).one()
    return InternalLicenseResponse(
        table_id=table.id,
        client_id=table.client_id,
        status=licenses.status(datetime.now(UTC), license_.paid_until, license_.suspended),
        paid_until=license_.paid_until,
        grace_until=licenses.grace_until(license_.paid_until),
    )


@router.get("/jwt-key")
def jwt_key() -> InternalJwtKeyResponse:
    """The public key media-server verifies access tokens with; it checks each token locally (ADR-7)."""
    return InternalJwtKeyResponse(algorithm="EdDSA", public_key_pem=public_key_pem())
