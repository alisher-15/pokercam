import uuid
from typing import Any

from sqlalchemy.orm import Session

from app.models import AuditLog


def record(
    session: Session,
    *,
    actor: str,
    action: str,
    entity: str,
    entity_id: uuid.UUID | str | None = None,
    client_id: uuid.UUID | None = None,
    payload: dict[str, Any] | None = None,
) -> None:
    """Adds an audit_log row to the caller's transaction (SPEC 9.3: every admin change, plus pairing events)."""
    session.add(
        AuditLog(
            actor=actor,
            action=action,
            entity=entity,
            entity_id=str(entity_id) if entity_id is not None else None,
            client_id=client_id,
            payload=payload or {},
        )
    )
