"""Admin panel /admin (SPEC 9.3): server-rendered Jinja2 pages, HTMX boost, ru/en.

Every change goes through _change(), which writes the audit_log row in the same transaction.
"""

import json
import re
import uuid
from datetime import UTC, date, datetime, time, timedelta
from pathlib import Path
from typing import Annotated, Any
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import SessionDep
from app.config import get_settings
from app.models import AdminUser, AuditLog, Brand, Client, Device, License, PokerTable, Viewer
from app.security import keyed_hash, new_activation_key, normalize_activation_key, verify_password
from app.services import audit, licenses
from app.services.ratelimit import RateLimiter

HERE = Path(__file__).parent
STATIC_DIR = HERE / "static"
LANGUAGES = ("ru", "en")
_CATALOGS: dict[str, dict[str, str]] = {
    lang: json.loads((HERE / "locales" / f"{lang}.json").read_text(encoding="utf-8")) for lang in LANGUAGES
}

templates = Jinja2Templates(directory=HERE / "templates")
router = APIRouter(prefix="/admin", include_in_schema=False)
login_limiter = RateLimiter(limit=5)


class LoginRequired(Exception):
    pass


def install(app: FastAPI) -> None:
    @app.exception_handler(LoginRequired)
    async def to_login(_: Request, __: LoginRequired) -> Response:
        return RedirectResponse("/admin/login", status_code=303)


def language(request: Request) -> str:
    chosen = request.cookies.get("lang")
    if chosen in LANGUAGES:
        return chosen
    return "ru" if "ru" in request.headers.get("accept-language", "").lower() else "en"


def translate(lang: str, key: str, **values: Any) -> str:
    text = _CATALOGS[lang].get(key, key)
    return text.format(**values) if values else text


def _local(moment: datetime | None) -> str:
    if moment is None:
        return "—"
    return moment.astimezone(ZoneInfo(get_settings().timezone)).strftime("%Y-%m-%d %H:%M")


def _page(request: Request, name: str, **context: Any) -> HTMLResponse:
    lang = language(request)
    return templates.TemplateResponse(
        request,
        name,
        {
            "t": lambda key, **values: translate(lang, key, **values),
            "lang": lang,
            "languages": LANGUAGES,
            "local": _local,
            "timezone": get_settings().timezone,
            "error": request.query_params.get("error"),
            **context,
        },
    )


def current_admin(request: Request, session: SessionDep) -> AdminUser:
    admin_id = request.session.get("admin_id")
    admin = session.get(AdminUser, uuid.UUID(admin_id)) if admin_id else None
    if admin is None:
        raise LoginRequired
    return admin


AdminDep = Annotated[AdminUser, Depends(current_admin)]


def _change(
    session: Session,
    admin: AdminUser,
    action: str,
    entity: str,
    entity_id: Any,
    client_id: uuid.UUID | None,
    **payload: Any,
) -> None:
    audit.record(
        session,
        actor=f"admin:{admin.email}",
        action=action,
        entity=entity,
        entity_id=entity_id,
        client_id=client_id,
        payload={k: (v.isoformat() if isinstance(v, datetime) else v) for k, v in payload.items()},
    )
    session.commit()


def _back(url: str, error: str | None = None) -> RedirectResponse:
    return RedirectResponse(f"{url}?error={error}" if error else url, status_code=303)


def _client(session: Session, client_id: uuid.UUID) -> Client:
    return session.get_one(Client, client_id)


def _now() -> datetime:
    return datetime.now(UTC)


# ---------------------------------------------------------------- sign in


@router.get("/lang/{lang}")
def set_language(lang: str, request: Request) -> Response:
    response = RedirectResponse(request.headers.get("referer") or "/admin", status_code=303)
    if lang in LANGUAGES:
        response.set_cookie("lang", lang, max_age=365 * 86400, samesite="strict")
    return response


@router.get("/login")
def login_page(request: Request) -> HTMLResponse:
    return _page(request, "login.html")


@router.post("/login")
def login(
    request: Request, session: SessionDep, email: Annotated[str, Form()], password: Annotated[str, Form()]
) -> Response:
    if not login_limiter.allow(request.client.host if request.client else "unknown"):
        return _back("/admin/login", "too_many_attempts")
    admin = session.scalar(select(AdminUser).where(AdminUser.email == email.strip().lower()))
    if admin is None or not verify_password(admin.password_hash, password):
        return _back("/admin/login", "wrong_login")
    request.session["admin_id"] = str(admin.id)
    return RedirectResponse("/admin/clients", status_code=303)


@router.post("/logout")
def logout(request: Request) -> Response:
    request.session.clear()
    return RedirectResponse("/admin/login", status_code=303)


@router.get("")
def home(_: AdminDep) -> Response:
    return RedirectResponse("/admin/clients", status_code=303)


# ---------------------------------------------------------------- clients and licenses


@router.get("/clients")
def clients_page(request: Request, admin: AdminDep, session: SessionDep) -> HTMLResponse:
    now = _now()
    rows = []
    for client in session.scalars(select(Client).order_by(Client.name)).unique():
        lic = client.license
        tables = session.scalar(select(func.count()).where(PokerTable.client_id == client.id))
        rows.append(
            {
                "client": client,
                "status": licenses.status(now, lic.paid_until, lic.suspended).value,
                "paid_until": lic.paid_until,
                "tables": tables,
                "max_tables": lic.max_tables,
            }
        )
    brands = session.scalars(select(Brand).order_by(Brand.app_name)).all()
    return _page(request, "clients.html", admin=admin, rows=rows, brands=brands)


@router.post("/clients")
def create_client(
    request: Request,
    admin: AdminDep,
    session: SessionDep,
    name: Annotated[str, Form()],
    brand_id: Annotated[uuid.UUID, Form()],
    max_tables: Annotated[int, Form()] = 1,
    paid: Annotated[bool, Form()] = False,
) -> Response:
    if not name.strip() or session.get(Brand, brand_id) is None or max_tables < 0:
        return _back("/admin/clients", "invalid_form")
    key = new_activation_key()
    client = Client(name=name.strip(), brand_id=brand_id, activation_key_hash=keyed_hash(normalize_activation_key(key)))
    session.add(client)
    session.flush()
    now = _now()
    # Unpaid: already past the grace period, so nothing works until «+1 месяц».
    paid_until = licenses.add_month(now) if paid else now - licenses.GRACE - timedelta(seconds=1)
    session.add(License(client_id=client.id, paid_until=paid_until, max_tables=max_tables))
    _change(session, admin, "client.created", "client", client.id, client.id, name=client.name, paid_until=paid_until)
    return _page(request, "key.html", admin=admin, client=client, key=key)


@router.get("/clients/{client_id}")
def client_page(client_id: uuid.UUID, request: Request, admin: AdminDep, session: SessionDep) -> HTMLResponse:
    client = _client(session, client_id)
    lic = client.license
    now = _now()
    return _page(
        request,
        "client.html",
        admin=admin,
        client=client,
        license=lic,
        status=licenses.status(now, lic.paid_until, lic.suspended).value,
        grace_until=licenses.grace_until(lic.paid_until),
        brands=session.scalars(select(Brand).order_by(Brand.app_name)).all(),
        tables=session.scalars(
            select(PokerTable).where(PokerTable.client_id == client.id).order_by(PokerTable.number)
        ).all(),
        devices=session.scalars(
            select(Device).where(Device.client_id == client.id).order_by(Device.paired_at.desc())
        ).all(),
        viewers=session.scalars(
            select(Viewer).where(Viewer.client_id == client.id).order_by(Viewer.created_at.desc())
        ).all(),
        history=session.scalars(
            select(AuditLog).where(AuditLog.client_id == client.id).order_by(AuditLog.id.desc()).limit(20)
        ).all(),
    )


@router.post("/clients/{client_id}/edit")
def edit_client(
    client_id: uuid.UUID,
    admin: AdminDep,
    session: SessionDep,
    name: Annotated[str, Form()],
    brand_id: Annotated[uuid.UUID, Form()],
) -> Response:
    client = _client(session, client_id)
    url = f"/admin/clients/{client_id}"
    if not name.strip() or session.get(Brand, brand_id) is None:
        return _back(url, "invalid_form")
    client.name, client.brand_id = name.strip(), brand_id
    _change(session, admin, "client.updated", "client", client.id, client.id, name=client.name, brand_id=str(brand_id))
    return _back(url)


@router.post("/clients/{client_id}/extend")
def extend_license(client_id: uuid.UUID, admin: AdminDep, session: SessionDep) -> Response:
    """«+1 месяц»: a cash payment received now."""
    lic = _client(session, client_id).license
    before = lic.paid_until
    lic.paid_until = licenses.extend_by_month(before, _now())
    _change(
        session,
        admin,
        "license.extended",
        "license",
        lic.id,
        client_id,
        paid_until_before=before,
        paid_until=lic.paid_until,
    )
    return _back(f"/admin/clients/{client_id}")


@router.post("/clients/{client_id}/paid-until")
def set_paid_until(
    client_id: uuid.UUID, admin: AdminDep, session: SessionDep, paid_until: Annotated[date, Form()]
) -> Response:
    """A date typed by hand: access lasts to the end of that day in the admin's time zone."""
    lic = _client(session, client_id).license
    before = lic.paid_until
    lic.paid_until = datetime.combine(paid_until, time(23, 59, 59), ZoneInfo(get_settings().timezone))
    _change(
        session,
        admin,
        "license.paid_until_set",
        "license",
        lic.id,
        client_id,
        paid_until_before=before,
        paid_until=lic.paid_until,
    )
    return _back(f"/admin/clients/{client_id}")


@router.post("/clients/{client_id}/suspend")
def suspend_license(client_id: uuid.UUID, admin: AdminDep, session: SessionDep) -> Response:
    lic = _client(session, client_id).license
    lic.suspended = True
    _change(session, admin, "license.suspended", "license", lic.id, client_id)
    return _back(f"/admin/clients/{client_id}")


@router.post("/clients/{client_id}/resume")
def resume_license(client_id: uuid.UUID, admin: AdminDep, session: SessionDep) -> Response:
    lic = _client(session, client_id).license
    lic.suspended = False
    _change(session, admin, "license.resumed", "license", lic.id, client_id)
    return _back(f"/admin/clients/{client_id}")


@router.post("/clients/{client_id}/max-tables")
def set_max_tables(
    client_id: uuid.UUID, admin: AdminDep, session: SessionDep, max_tables: Annotated[int, Form()]
) -> Response:
    lic = _client(session, client_id).license
    url = f"/admin/clients/{client_id}"
    existing = session.scalar(select(func.count()).where(PokerTable.client_id == client_id)) or 0
    if max_tables < existing:
        return _back(url, "max_below_tables")
    lic.max_tables = max_tables
    _change(session, admin, "license.max_tables_set", "license", lic.id, client_id, max_tables=max_tables)
    return _back(url)


@router.post("/clients/{client_id}/reissue-key")
def reissue_key(client_id: uuid.UUID, request: Request, admin: AdminDep, session: SessionDep) -> Response:
    """The old key stops working for new activations; PCs already activated keep working until revoked."""
    client = _client(session, client_id)
    key = new_activation_key()
    client.activation_key_hash = keyed_hash(normalize_activation_key(key))
    _change(session, admin, "client.key_reissued", "client", client.id, client.id)
    return _page(request, "key.html", admin=admin, client=client, key=key)


# ---------------------------------------------------------------- tables, phones, PCs


@router.post("/clients/{client_id}/tables")
def create_table(
    client_id: uuid.UUID,
    admin: AdminDep,
    session: SessionDep,
    name: Annotated[str, Form()],
    number: Annotated[int, Form()],
) -> Response:
    lic = _client(session, client_id).license
    url = f"/admin/clients/{client_id}"
    existing = session.scalars(select(PokerTable.number).where(PokerTable.client_id == client_id)).all()
    if len(existing) >= lic.max_tables:
        return _back(url, "table_limit")
    if not name.strip() or number < 1 or number in existing:
        return _back(url, "invalid_form")
    table = PokerTable(client_id=client_id, name=name.strip(), number=number)
    session.add(table)
    session.flush()
    _change(session, admin, "table.created", "poker_table", table.id, client_id, name=table.name, number=number)
    return _back(url)


@router.post("/clients/{client_id}/tables/{table_id}/delete")
def delete_table(client_id: uuid.UUID, table_id: uuid.UUID, admin: AdminDep, session: SessionDep) -> Response:
    table = session.get_one(PokerTable, table_id)
    if table.client_id != client_id:
        return _back(f"/admin/clients/{client_id}", "invalid_form")
    now = _now()
    for device in session.scalars(select(Device).where(Device.table_id == table_id, Device.revoked_at.is_(None))):
        device.revoked_at = now
    session.delete(table)
    _change(session, admin, "table.deleted", "poker_table", table_id, client_id, name=table.name, number=table.number)
    return _back(f"/admin/clients/{client_id}")


@router.post("/clients/{client_id}/devices/{device_id}/revoke")
def revoke_device(client_id: uuid.UUID, device_id: uuid.UUID, admin: AdminDep, session: SessionDep) -> Response:
    device = session.get_one(Device, device_id)
    if device.client_id == client_id and device.revoked_at is None:
        device.revoked_at = _now()
        _change(session, admin, "device.revoked", "device", device.id, client_id, reason="admin")
    return _back(f"/admin/clients/{client_id}")


@router.post("/clients/{client_id}/viewers/{viewer_id}/revoke")
def revoke_viewer(client_id: uuid.UUID, viewer_id: uuid.UUID, admin: AdminDep, session: SessionDep) -> Response:
    viewer = session.get_one(Viewer, viewer_id)
    if viewer.client_id == client_id and viewer.revoked_at is None:
        viewer.revoked_at = _now()
        _change(session, admin, "viewer.revoked", "viewer", viewer.id, client_id, name=viewer.name)
    return _back(f"/admin/clients/{client_id}")


# ---------------------------------------------------------------- brands


def _brand_form(
    app_name: str, android_application_id: str, logo_url: str, colors: dict[str, str]
) -> dict[str, Any] | None:
    """Brand fields if valid (the rules of contracts/branding/brand_config.json), else None."""
    if not app_name.strip() or not re.fullmatch(r"[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+", android_application_id):
        return None
    if not all(re.fullmatch(r"#[0-9A-Fa-f]{6}", c) for c in colors.values()):
        return None
    return {
        "app_name": app_name.strip(),
        "android_application_id": android_application_id,
        "logo_url": logo_url.strip() or None,
        "colors": colors,
    }


@router.get("/brands")
def brands_page(request: Request, admin: AdminDep, session: SessionDep) -> HTMLResponse:
    brands = session.scalars(select(Brand).order_by(Brand.app_name)).all()
    return _page(request, "brands.html", admin=admin, brands=brands)


@router.post("/brands")
def save_brand(
    admin: AdminDep,
    session: SessionDep,
    app_name: Annotated[str, Form()],
    android_application_id: Annotated[str, Form()],
    primary: Annotated[str, Form()],
    secondary: Annotated[str, Form()],
    background: Annotated[str, Form()],
    accent: Annotated[str, Form()],
    logo_url: Annotated[str, Form()] = "",
    brand_id: Annotated[uuid.UUID | None, Form()] = None,
) -> Response:
    """Creates a brand, or updates `brand_id`."""
    colors = {"primary": primary, "secondary": secondary, "background": background, "accent": accent}
    fields = _brand_form(app_name, android_application_id, logo_url, colors)
    if fields is None:
        return _back("/admin/brands", "invalid_form")
    if brand_id is None:
        brand = Brand(**fields)
        session.add(brand)
        session.flush()
        action = "brand.created"
    else:
        brand = session.get_one(Brand, brand_id)
        for key, value in fields.items():
            setattr(brand, key, value)
        action = "brand.updated"
    _change(session, admin, action, "brand", brand.id, None, **{k: v for k, v in fields.items() if k != "colors"})
    return _back("/admin/brands")


# ---------------------------------------------------------------- audit log


@router.get("/audit")
def audit_page(
    request: Request, admin: AdminDep, session: SessionDep, client_id: uuid.UUID | None = None
) -> HTMLResponse:
    query = select(AuditLog).order_by(AuditLog.id.desc()).limit(200)
    if client_id is not None:
        query = query.where(AuditLog.client_id == client_id)
    clients = session.scalars(select(Client).order_by(Client.name)).unique().all()
    return _page(
        request,
        "audit.html",
        admin=admin,
        entries=session.scalars(query).all(),
        clients=clients,
        client_id=client_id,
    )
