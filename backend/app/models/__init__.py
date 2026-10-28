from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    """Base of every table. Models arrive in stage 2 (SPEC 5.1)."""
