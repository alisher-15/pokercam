"""brand.seller_contacts: how a club reaches its seller (SPEC 8.4, stage 8).

Revision ID: 0003
Revises: 0002
Create Date: 2026-11-21
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("brand", sa.Column("seller_contacts", postgresql.JSONB(), nullable=True))


def downgrade() -> None:
    op.drop_column("brand", "seller_contacts")
