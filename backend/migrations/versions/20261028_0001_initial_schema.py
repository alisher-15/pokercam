"""Initial schema: the tables of SPEC 5.1.

Revision ID: 0001
Revises:
Create Date: 2026-10-28
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "admin_user",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("email", sa.Text(), nullable=False),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("email"),
    )
    op.create_table(
        "audit_log",
        sa.Column("id", sa.BigInteger(), sa.Identity(always=False), nullable=False),
        sa.Column("actor", sa.Text(), nullable=False),
        sa.Column("action", sa.Text(), nullable=False),
        sa.Column("entity", sa.Text(), nullable=False),
        sa.Column("entity_id", sa.Text(), nullable=True),
        sa.Column("client_id", sa.Uuid(), nullable=True),
        sa.Column(
            "payload", postgresql.JSONB(astext_type=sa.Text()), server_default=sa.text("'{}'::jsonb"), nullable=False
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("audit_log_by_client", "audit_log", ["client_id", "created_at"], unique=False)
    op.create_index(op.f("ix_audit_log_created_at"), "audit_log", ["created_at"], unique=False)
    op.create_table(
        "brand",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("app_name", sa.Text(), nullable=False),
        sa.Column("logo_url", sa.Text(), nullable=True),
        sa.Column("colors", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("android_application_id", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "client",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("brand_id", sa.Uuid(), nullable=False),
        sa.Column("activation_key_hash", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(
            ["brand_id"],
            ["brand.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("activation_key_hash"),
    )
    op.create_table(
        "license",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column("paid_until", sa.DateTime(timezone=True), nullable=False),
        sa.Column("max_tables", sa.Integer(), server_default=sa.text("1"), nullable=False),
        sa.Column("suspended", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["client_id"], ["client.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("client_id"),
    )
    op.create_table(
        "poker_table",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("number", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["client_id"], ["client.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("client_id", "number"),
    )
    op.create_table(
        "viewer",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column("machine_id_hash", sa.Text(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("refresh_token_hash", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["client_id"], ["client.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("client_id", "machine_id_hash"),
        sa.UniqueConstraint("refresh_token_hash"),
    )
    op.create_table(
        "device",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column("table_id", sa.Uuid(), nullable=True),
        sa.Column("model", sa.Text(), nullable=False),
        sa.Column("android_id_hash", sa.Text(), nullable=False),
        sa.Column("refresh_token_hash", sa.Text(), nullable=False),
        sa.Column("paired_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["client_id"], ["client.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["table_id"], ["poker_table.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("refresh_token_hash"),
    )
    op.create_index(
        "one_live_device_per_table", "device", ["table_id"], unique=True, postgresql_where=sa.text("revoked_at IS NULL")
    )
    op.create_table(
        "pairing_code",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("code_hash", sa.Text(), nullable=False),
        sa.Column("table_id", sa.Uuid(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["table_id"], ["poker_table.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_pairing_code_code_hash"), "pairing_code", ["code_hash"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_pairing_code_code_hash"), table_name="pairing_code")
    op.drop_table("pairing_code")
    op.drop_index("one_live_device_per_table", table_name="device", postgresql_where=sa.text("revoked_at IS NULL"))
    op.drop_table("device")
    op.drop_table("viewer")
    op.drop_table("poker_table")
    op.drop_table("license")
    op.drop_table("client")
    op.drop_table("brand")
    op.drop_index(op.f("ix_audit_log_created_at"), table_name="audit_log")
    op.drop_index("audit_log_by_client", table_name="audit_log")
    op.drop_table("audit_log")
    op.drop_table("admin_user")
