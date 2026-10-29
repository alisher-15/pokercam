"""Pairing codes (SPEC 9.2): one-time, 5 minutes, stored only as a hash."""

import json
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.errors import ApiException
from app.config import get_settings
from app.models import PairingCode, PokerTable
from app.security import keyed_hash, new_pairing_code
from app.services import audit

PAIRING_CODE_TTL = timedelta(minutes=5)


def issue_code(session: Session, table: PokerTable, actor: str, now: datetime) -> tuple[str, datetime]:
    """A new code for the table, unique among live codes; recorded in the audit log. The caller commits."""
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
        actor=actor,
        action="pairing_code.created",
        entity="poker_table",
        entity_id=table.id,
        client_id=table.client_id,
    )
    return code, expires_at


def qr_payload(code: str) -> str:
    """What the PC's QR code carries: the backend's address and the code (apps/shared PairingQr)."""
    return json.dumps({"v": 1, "api": get_settings().public_api_url, "code": code}, separators=(",", ":"))
