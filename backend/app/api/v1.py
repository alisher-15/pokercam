"""Public REST API of SPEC 5.2. Bodies are the classes generated from contracts/rest."""

import json
import uuid
from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, Request
from sqlalchemy import select

from app.api.deps import ClaimsDep, SessionDep, ViewerDep, check_rate
from app.api.errors import ERRORS, ApiException
from app.config import get_settings
from app.contracts.common import LicenseStatus, Role
from app.contracts.rest.brand_response import BrandResponse
from app.contracts.rest.device_pair_request import DevicePairRequest
from app.contracts.rest.device_pair_response import DevicePairResponse
from app.contracts.rest.license_response import LicenseResponse
from app.contracts.rest.pairing_code_response import PairingCodeResponse
from app.contracts.rest.table_list_response import TableInfo, TableListResponse
from app.contracts.rest.token_request import TokenRequest
from app.contracts.rest.token_response import TokenResponse
from app.contracts.rest.viewer_activate_request import ViewerActivateRequest
from app.contracts.rest.viewer_activate_response import ViewerActivateResponse
from app.models import Client, Device, License, PairingCode, PokerTable, Viewer
from app.security import (
    issue_access_token,
    keyed_hash,
    new_pairing_code,
    new_refresh_token,
    normalize_activation_key,
    token_hash,
)
from app.services import audit, licenses
from app.services.ratelimit import RateLimiter

router = APIRouter(prefix="/api/v1", responses=ERRORS)

PAIRING_CODE_TTL = timedelta(minutes=5)

# SPEC 9.2: at most 5 code attempts a minute from one IP. Activation keys get the same guard.
pairing_limiter = RateLimiter(limit=5)
activation_limiter = RateLimiter(limit=5)

# The no-nulls rule of contracts/README.md.
_NO_NULLS = {"response_model_exclude_none": True}


def _now() -> datetime:
    return datetime.now(UTC)


def _license(session: SessionDep, client_id: uuid.UUID) -> License:
    license_ = session.scalar(select(License).where(License.client_id == client_id))
    if license_ is None:
        raise ApiException(403, "no_license", "The client has no license")
    return license_


def _require_access(license_: License, now: datetime) -> LicenseStatus:
    """Active or grace; anything else is the reason access is refused."""
    status = licenses.status(now, license_.paid_until, license_.suspended)
    if status == LicenseStatus.EXPIRED:
        raise ApiException(403, "license_expired", "The license has expired")
    if status == LicenseStatus.SUSPENDED:
        raise ApiException(403, "license_suspended", "The license is suspended")
    return status


def _own_table(session: SessionDep, table_id: uuid.UUID, client_id: uuid.UUID) -> PokerTable:
    table = session.get(PokerTable, table_id)
    if table is None or table.client_id != client_id:
        raise ApiException(404, "table_not_found", "No such table for this client")
    return table


@router.post("/viewer/activate", **_NO_NULLS)
def activate_viewer(body: ViewerActivateRequest, request: Request, session: SessionDep) -> ViewerActivateResponse:
    """A Windows PC enters the club's key once and gets its refresh token."""
    check_rate(activation_limiter, request)
    key_hash = keyed_hash(normalize_activation_key(body.activation_key))
    client = session.scalar(select(Client).where(Client.activation_key_hash == key_hash))
    if client is None:
        raise ApiException(401, "invalid_activation_key", "Unknown activation key")
    machine_hash = keyed_hash(body.machine_id)
    viewer = session.scalar(select(Viewer).where(Viewer.client_id == client.id, Viewer.machine_id_hash == machine_hash))
    token = new_refresh_token()
    if viewer is None:
        viewer = Viewer(client_id=client.id, machine_id_hash=machine_hash, name=body.name or "PC")
        session.add(viewer)
    elif body.name:
        viewer.name = body.name
    # Entering the club's key again brings a revoked PC back: to lock a PC out, reissue the key.
    viewer.revoked_at = None
    viewer.refresh_token_hash = token_hash(token)
    viewer.last_seen_at = _now()
    session.flush()
    audit.record(
        session,
        actor=f"viewer:{viewer.id}",
        action="viewer.activated",
        entity="viewer",
        entity_id=viewer.id,
        client_id=client.id,
        payload={"name": viewer.name},
    )
    session.commit()
    return ViewerActivateResponse(refresh_token=token, viewer_id=viewer.id, client_id=client.id)


@router.post("/device/pair", **_NO_NULLS)
def pair_device(body: DevicePairRequest, request: Request, session: SessionDep) -> DevicePairResponse:
    """A phone sends the code from the QR; the table's previous phone is revoked (SPEC 9.2)."""
    check_rate(pairing_limiter, request)
    now = _now()
    code = session.scalar(
        select(PairingCode)
        .where(PairingCode.code_hash == keyed_hash(body.code))
        .order_by(PairingCode.created_at.desc())
        .limit(1)
        .with_for_update()
    )
    if code is None:
        raise ApiException(400, "pairing_code_invalid", "No such pairing code")
    if code.used_at is not None:
        raise ApiException(400, "pairing_code_used", "This pairing code has already been used")
    if now > code.expires_at:
        raise ApiException(400, "pairing_code_expired", "This pairing code has expired: show a new one on the PC")
    table = session.get_one(PokerTable, code.table_id)

    for old in session.scalars(select(Device).where(Device.table_id == table.id, Device.revoked_at.is_(None))):
        old.revoked_at = now
        audit.record(
            session,
            actor="system",
            action="device.revoked",
            entity="device",
            entity_id=old.id,
            client_id=table.client_id,
            payload={"reason": "replaced", "table_id": str(table.id)},
        )
    session.flush()

    token = new_refresh_token()
    device = Device(
        client_id=table.client_id,
        table_id=table.id,
        model=body.model,
        android_id_hash=keyed_hash(body.android_id),
        refresh_token_hash=token_hash(token),
        last_seen_at=now,
    )
    session.add(device)
    code.used_at = now
    session.flush()
    audit.record(
        session,
        actor=f"device:{device.id}",
        action="device.paired",
        entity="device",
        entity_id=device.id,
        client_id=table.client_id,
        payload={"table_id": str(table.id), "model": body.model},
    )
    session.commit()
    return DevicePairResponse(refresh_token=token, device_id=device.id, table_id=table.id, client_id=table.client_id)


@router.post("/auth/token", **_NO_NULLS)
def issue_token(body: TokenRequest, session: SessionDep) -> TokenResponse:
    """Refresh token -> access JWT. Refused once the license is expired or suspended."""
    now = _now()
    hashed = token_hash(body.refresh_token)
    device = session.scalar(select(Device).where(Device.refresh_token_hash == hashed))
    viewer = None if device else session.scalar(select(Viewer).where(Viewer.refresh_token_hash == hashed))
    subject = device or viewer
    if subject is None:
        raise ApiException(401, "invalid_refresh_token", "Unknown refresh token")
    if subject.revoked_at is not None:
        raise ApiException(401, "access_revoked", "This device has been revoked")
    lic = _require_access(_license(session, subject.client_id), now)

    if device is not None:
        if device.table_id is None:
            raise ApiException(401, "access_revoked", "The phone's table no longer exists")
        if body.table_id is not None and body.table_id != device.table_id:
            raise ApiException(400, "wrong_table", "A phone gets tokens for its own table only")
        role, table_id = Role.CAMERA, device.table_id
    else:
        role, table_id = Role.VIEWER, body.table_id
        if table_id is not None:
            _own_table(session, table_id, subject.client_id)

    subject.last_seen_at = now
    session.commit()
    token, ttl = issue_access_token(
        {
            "sub": str(subject.id),
            "role": role.value,
            "client_id": str(subject.client_id),
            "table_id": str(table_id) if table_id else None,
            "lic": lic.value,
        }
    )
    return TokenResponse(
        access_token=token, token_type="bearer", expires_in=ttl, media_url=get_settings().public_media_url
    )


@router.get("/license", **_NO_NULLS)
def get_license(claims: ClaimsDep, session: SessionDep) -> LicenseResponse:
    """check_license of SPEC 9.1: called at start and hourly by both apps."""
    license_ = _license(session, claims.client_id)
    return LicenseResponse(
        status=licenses.status(_now(), license_.paid_until, license_.suspended),
        paid_until=license_.paid_until,
        grace_until=licenses.grace_until(license_.paid_until),
    )


@router.get("/tables", **_NO_NULLS)
def list_tables(claims: ViewerDep, session: SessionDep) -> TableListResponse:
    """Tables with their cameras: online while the camera publishes to media-server (it reports that)."""
    tables = session.scalars(
        select(PokerTable).where(PokerTable.client_id == claims.client_id).order_by(PokerTable.number)
    ).all()
    cameras = {
        d.table_id: d
        for d in session.scalars(
            select(Device).where(Device.client_id == claims.client_id, Device.revoked_at.is_(None))
        )
    }
    items = []
    for table in tables:
        camera = cameras.get(table.id)
        items.append(
            TableInfo(
                id=table.id,
                name=table.name,
                number=table.number,
                camera_online=table.camera_connected_at is not None,
                camera_last_seen_at=camera.last_seen_at if camera else None,
            )
        )
    return TableListResponse(tables=items)


@router.post("/tables/{table_id}/pairing-code", **_NO_NULLS)
def create_pairing_code(table_id: uuid.UUID, claims: ViewerDep, session: SessionDep) -> PairingCodeResponse:
    """The PC shows this code and QR; a phone that sends it within 5 minutes becomes the table's camera."""
    now = _now()
    table = _own_table(session, table_id, claims.client_id)
    _require_access(_license(session, claims.client_id), now)
    live = select(PairingCode.id).where(PairingCode.used_at.is_(None), PairingCode.expires_at >= now)
    for _ in range(10):
        code = new_pairing_code()
        if session.scalar(live.where(PairingCode.code_hash == keyed_hash(code))) is None:
            break
    else:
        raise ApiException(409, "conflict", "Could not find a free pairing code, try again")
    expires_at = now + PAIRING_CODE_TTL
    session.add(PairingCode(code_hash=keyed_hash(code), table_id=table.id, expires_at=expires_at))
    audit.record(
        session,
        actor=f"viewer:{claims.sub}",
        action="pairing_code.created",
        entity="poker_table",
        entity_id=table.id,
        client_id=claims.client_id,
    )
    session.commit()
    qr = json.dumps({"v": 1, "api": get_settings().public_api_url, "code": code}, separators=(",", ":"))
    return PairingCodeResponse(code=code, expires_at=expires_at, qr_payload=qr)


@router.get("/brand", **_NO_NULLS)
def get_brand(claims: ClaimsDep, session: SessionDep) -> BrandResponse:
    brand = session.get_one(Client, claims.client_id).brand
    return BrandResponse.model_validate(
        {"app_name": brand.app_name, "logo_url": brand.logo_url, "colors": brand.colors}
    )
