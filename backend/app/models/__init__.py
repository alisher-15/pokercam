"""Tables of SPEC 5.1. License status is computed (app.services.licenses), never stored."""

import uuid
from datetime import datetime
from typing import Any, ClassVar

from sqlalchemy import BigInteger, ForeignKey, Identity, Index, Text, UniqueConstraint, func, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship
from sqlalchemy.types import DateTime


class Base(DeclarativeBase):
    type_annotation_map: ClassVar[dict[Any, Any]] = {datetime: DateTime(timezone=True), dict[str, Any]: JSONB}


def _id() -> Mapped[uuid.UUID]:
    return mapped_column(primary_key=True, default=uuid.uuid4)


def _created() -> Mapped[datetime]:
    return mapped_column(server_default=func.now())


class Brand(Base):
    __tablename__ = "brand"

    id: Mapped[uuid.UUID] = _id()
    app_name: Mapped[str] = mapped_column(Text)
    logo_url: Mapped[str | None] = mapped_column(Text)
    # BrandColors of contracts/common.json: primary, secondary, background, accent.
    colors: Mapped[dict[str, Any]]
    android_application_id: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = _created()


class Client(Base):
    """A club: one brand, one license, its tables, phones and PCs."""

    __tablename__ = "client"

    id: Mapped[uuid.UUID] = _id()
    name: Mapped[str] = mapped_column(Text)
    brand_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("brand.id"))
    activation_key_hash: Mapped[str] = mapped_column(Text, unique=True)
    created_at: Mapped[datetime] = _created()

    brand: Mapped[Brand] = relationship(lazy="joined")
    license: Mapped["License"] = relationship(back_populates="client", lazy="joined")


class License(Base):
    __tablename__ = "license"

    id: Mapped[uuid.UUID] = _id()
    client_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("client.id", ondelete="CASCADE"), unique=True)
    paid_until: Mapped[datetime]
    # SPEC 2: the pilot runs one table per client.
    max_tables: Mapped[int] = mapped_column(default=1, server_default=text("1"))
    suspended: Mapped[bool] = mapped_column(default=False, server_default=text("false"))
    updated_at: Mapped[datetime] = mapped_column(server_default=func.now(), onupdate=func.now())

    client: Mapped[Client] = relationship(back_populates="license")


class PokerTable(Base):
    __tablename__ = "poker_table"
    __table_args__ = (UniqueConstraint("client_id", "number"),)

    id: Mapped[uuid.UUID] = _id()
    client_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("client.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(Text)
    number: Mapped[int]
    created_at: Mapped[datetime] = _created()


class Device(Base):
    """A camera phone. A table has at most one device that is not revoked."""

    __tablename__ = "device"
    __table_args__ = (
        Index("one_live_device_per_table", "table_id", unique=True, postgresql_where=text("revoked_at IS NULL")),
    )

    id: Mapped[uuid.UUID] = _id()
    client_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("client.id", ondelete="CASCADE"))
    table_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("poker_table.id", ondelete="SET NULL"))
    model: Mapped[str] = mapped_column(Text)
    android_id_hash: Mapped[str] = mapped_column(Text)
    refresh_token_hash: Mapped[str] = mapped_column(Text, unique=True)
    paired_at: Mapped[datetime] = _created()
    last_seen_at: Mapped[datetime | None]
    revoked_at: Mapped[datetime | None]


class Viewer(Base):
    """A Windows PC activated with the club's key."""

    __tablename__ = "viewer"
    __table_args__ = (UniqueConstraint("client_id", "machine_id_hash"),)

    id: Mapped[uuid.UUID] = _id()
    client_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("client.id", ondelete="CASCADE"))
    machine_id_hash: Mapped[str] = mapped_column(Text)
    name: Mapped[str] = mapped_column(Text)
    refresh_token_hash: Mapped[str] = mapped_column(Text, unique=True)
    created_at: Mapped[datetime] = _created()
    last_seen_at: Mapped[datetime | None]
    revoked_at: Mapped[datetime | None]


class PairingCode(Base):
    """A 6-digit code shown on the PC; one use, 5 minutes (SPEC 9.2)."""

    __tablename__ = "pairing_code"

    id: Mapped[uuid.UUID] = _id()
    code_hash: Mapped[str] = mapped_column(Text, index=True)
    table_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("poker_table.id", ondelete="CASCADE"))
    expires_at: Mapped[datetime]
    used_at: Mapped[datetime | None]
    created_at: Mapped[datetime] = _created()


class AdminUser(Base):
    __tablename__ = "admin_user"

    id: Mapped[uuid.UUID] = _id()
    email: Mapped[str] = mapped_column(Text, unique=True)
    password_hash: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = _created()


class AuditLog(Base):
    """Every change made in the admin panel, and pairing and activation events (SPEC 9.3)."""

    __tablename__ = "audit_log"
    __table_args__ = (Index("audit_log_by_client", "client_id", "created_at"),)

    id: Mapped[int] = mapped_column(BigInteger, Identity(), primary_key=True)
    actor: Mapped[str] = mapped_column(Text)
    action: Mapped[str] = mapped_column(Text)
    entity: Mapped[str] = mapped_column(Text)
    entity_id: Mapped[str | None] = mapped_column(Text)
    # Not a foreign key: the history outlives a deleted client.
    client_id: Mapped[uuid.UUID | None]
    payload: Mapped[dict[str, Any]] = mapped_column(default=dict, server_default=text("'{}'::jsonb"))
    created_at: Mapped[datetime] = mapped_column(server_default=func.now(), index=True)
