"""python -m app.cli <command>: gen-keys, create-admin, create-client, seed, pairing-code."""

import argparse
import base64
import secrets
import sys
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import get_engine
from app.models import AdminUser, Brand, Client, License, PokerTable
from app.security import generate_private_key, hash_password, keyed_hash, new_activation_key, normalize_activation_key
from app.services import audit, licenses, pairing

# Neutral demo data: no real brand name lives in code (SPEC 10.1).
DEMO_BRAND = {
    "app_name": "Demo",
    "android_application_id": "com.example.demo.camera",
    "colors": {"primary": "#3F6E8C", "secondary": "#2B3138", "background": "#121417", "accent": "#C9A227"},
}
DEMO_CLIENT = "Demo club"


def gen_keys() -> None:
    """Lines for .env with fresh secrets."""
    print(f"JWT_PRIVATE_KEY={generate_private_key()}")
    print(f"HASH_SECRET={secrets.token_urlsafe(32)}")
    print(f"INTERNAL_API_TOKEN={secrets.token_urlsafe(32)}")
    print(f"ADMIN_SESSION_SECRET={base64.b64encode(secrets.token_bytes(32)).decode()}")


def create_admin(session: Session, email: str, password: str) -> bool:
    """Creates the admin, or sets a new password for an existing one. Returns whether it was created."""
    admin = session.scalar(select(AdminUser).where(AdminUser.email == email.lower()))
    created = admin is None
    if admin is None:
        admin = AdminUser(email=email.lower(), password_hash="")
        session.add(admin)
    admin.password_hash = hash_password(password)
    session.flush()
    audit.record(
        session,
        actor="cli",
        action="admin.created" if created else "admin.password_set",
        entity="admin_user",
        entity_id=admin.id,
    )
    return created


def create_client(session: Session, name: str, tables: int = 1) -> str:
    """A client with the demo brand, a paid month and `tables` tables; returns its activation key (shown once)."""
    brand = session.scalar(select(Brand).where(Brand.app_name == DEMO_BRAND["app_name"])) or Brand(**DEMO_BRAND)
    key = new_activation_key()
    client = Client(name=name, brand=brand, activation_key_hash=keyed_hash(normalize_activation_key(key)))
    session.add(client)
    session.flush()
    paid_until = licenses.add_month(datetime.now(UTC))
    session.add(License(client_id=client.id, paid_until=paid_until, max_tables=tables))
    session.add_all(PokerTable(client_id=client.id, name=str(n), number=n) for n in range(1, tables + 1))
    audit.record(
        session, actor="cli", action="client.created", entity="client", entity_id=client.id, client_id=client.id
    )
    return key


def seed(session: Session) -> str | None:
    """Demo brand, client with a paid month and one table (SPEC 9.3, pilot: one table), admin from .env.

    Returns the demo client's activation key when it was created now; it is shown only once.
    """
    settings = get_settings()
    if settings.admin_email and settings.admin_password:
        create_admin(session, settings.admin_email, settings.admin_password)
    if session.scalar(select(Client).where(Client.name == DEMO_CLIENT)) is not None:
        return None
    brand = Brand(**DEMO_BRAND)
    key = new_activation_key()
    client = Client(name=DEMO_CLIENT, brand=brand, activation_key_hash=keyed_hash(normalize_activation_key(key)))
    session.add(client)
    session.flush()
    session.add(License(client_id=client.id, paid_until=licenses.add_month(datetime.now(UTC)), max_tables=1))
    session.add(PokerTable(client_id=client.id, name="1", number=1))
    audit.record(session, actor="cli", action="seed", entity="client", entity_id=client.id, client_id=client.id)
    return key


def pairing_code(session: Session, client_name: str, table_number: int = 1) -> tuple[str, datetime]:
    """A phone pairing code for a client's table, as the Windows app would show it (SPEC 9.2).

    For setting up and testing a camera before the PC is there; the code lives 5 minutes.
    """
    client = session.scalar(select(Client).where(Client.name == client_name))
    if client is None:
        raise SystemExit(f"no client named {client_name!r}")
    table = session.scalar(
        select(PokerTable).where(PokerTable.client_id == client.id, PokerTable.number == table_number)
    )
    if table is None:
        raise SystemExit(f"{client_name!r} has no table {table_number}")
    return pairing.issue_code(session, table, "cli", datetime.now(UTC))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.cli")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("gen-keys", help="print fresh secrets for .env")
    admin = commands.add_parser("create-admin", help="create an admin or set its password")
    admin.add_argument("email")
    admin.add_argument("password")
    client = commands.add_parser("create-client", help="a client with a paid month; prints only its activation key")
    client.add_argument("name")
    client.add_argument("--tables", type=int, default=1)
    commands.add_parser("seed", help="demo brand, client and table; admin from ADMIN_EMAIL / ADMIN_PASSWORD")
    code = commands.add_parser("pairing-code", help="a 5-minute code that pairs a phone with a client's table")
    code.add_argument("client", help="the client's name, e.g. 'Demo club'")
    code.add_argument("--table", type=int, default=1)
    args = parser.parse_args(argv)

    if args.command == "gen-keys":
        gen_keys()
        return 0
    with Session(get_engine()) as session:
        if args.command == "create-admin":
            created = create_admin(session, args.email, args.password)
            print("admin created" if created else "admin password updated")
        elif args.command == "create-client":
            print(create_client(session, args.name, args.tables))
        elif args.command == "pairing-code":
            value, expires_at = pairing_code(session, args.client, args.table)
            print(f"code: {value}")
            print(f"server: {get_settings().public_api_url}")
            print(f"valid until: {expires_at:%H:%M:%S} UTC")
        else:
            key = seed(session)
            print(f"demo client created, activation key: {key}" if key else "demo data already there")
        session.commit()
    return 0


if __name__ == "__main__":
    sys.exit(main())
