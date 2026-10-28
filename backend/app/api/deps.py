import uuid
from typing import Annotated

import jwt
from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import ValidationError
from sqlalchemy.orm import Session

from app.api.errors import ApiException
from app.contracts.auth.access_token_claims import AccessTokenClaims
from app.contracts.common import Role
from app.db import get_session
from app.models import Device, Viewer
from app.security import decode_access_token
from app.services.ratelimit import RateLimiter

SessionDep = Annotated[Session, Depends(get_session)]
_bearer = HTTPBearer(auto_error=False, description="Access JWT from POST /api/v1/auth/token")


def current_claims(
    session: SessionDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> AccessTokenClaims:
    if credentials is None:
        raise ApiException(401, "unauthorized", "Bearer access token required")
    try:
        claims = decode_access_token(credentials.credentials)
    except (jwt.InvalidTokenError, ValidationError) as exc:
        raise ApiException(401, "invalid_token", "Access token is invalid or expired") from exc
    # A revoked phone or PC keeps a signed token until it expires; the API stops answering it at once.
    model = Device if claims.role == Role.CAMERA else Viewer
    subject = session.get(model, uuid.UUID(claims.sub))
    if subject is None or subject.revoked_at is not None:
        raise ApiException(401, "access_revoked", "This device has been revoked")
    return claims


ClaimsDep = Annotated[AccessTokenClaims, Depends(current_claims)]


def viewer_claims(claims: ClaimsDep) -> AccessTokenClaims:
    if claims.role != Role.VIEWER:
        raise ApiException(403, "viewers_only", "Only the Windows viewer may do this")
    return claims


ViewerDep = Annotated[AccessTokenClaims, Depends(viewer_claims)]


def check_rate(limiter: RateLimiter, request: Request) -> None:
    if not limiter.allow(request.client.host if request.client else "unknown"):
        raise ApiException(429, "too_many_attempts", f"At most {limiter.limit} attempts per minute")
