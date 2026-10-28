import re
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.admin.routes import _CATALOGS
from app.cli import create_admin
from app.contracts.common import LicenseStatus
from app.models import AuditLog, Brand, Client, Device, License, PokerTable, Viewer
from app.services.licenses import add_month
from tests.conftest import access_token, activate, pair_phone

EMAIL, PASSWORD = "admin@example.com", "admin-password-1"


@pytest.fixture
def admin(client: TestClient, db: Session) -> TestClient:
    """The test client signed in as an admin."""
    create_admin(db, EMAIL, PASSWORD)
    db.commit()
    response = client.post("/admin/login", data={"email": EMAIL, "password": PASSWORD}, follow_redirects=False)
    assert response.status_code == 303
    return client


def audit_actions(db: Session) -> list[str]:
    db.expire_all()
    return db.scalars(select(AuditLog.action).order_by(AuditLog.id)).all()


def fresh(db: Session, model, id_):
    db.expire_all()
    return db.get(model, id_)


def test_pages_need_sign_in(client: TestClient) -> None:
    for path in ("/admin", "/admin/clients", "/admin/brands", "/admin/audit"):
        response = client.get(path, follow_redirects=False)
        assert (response.status_code, response.headers["location"]) == (303, "/admin/login"), path


def test_wrong_password(client: TestClient, db: Session) -> None:
    create_admin(db, EMAIL, PASSWORD)
    db.commit()
    response = client.post("/admin/login", data={"email": EMAIL, "password": "nope"}, follow_redirects=False)
    assert response.headers["location"] == "/admin/login?error=wrong_login"


def test_sign_in_is_rate_limited(client: TestClient) -> None:
    for _ in range(5):
        client.post("/admin/login", data={"email": "x@example.com", "password": "x"})
    response = client.post("/admin/login", data={"email": EMAIL, "password": PASSWORD}, follow_redirects=False)
    assert response.headers["location"] == "/admin/login?error=too_many_attempts"


def test_pages_render_in_both_languages(admin: TestClient, make_club) -> None:
    club = make_club()
    for lang, word in (("ru", "Клиенты"), ("en", "Clients")):
        admin.cookies.set("lang", lang)
        for path in ("/admin/clients", f"/admin/clients/{club.client.id}", "/admin/brands", "/admin/audit"):
            response = admin.get(path)
            assert response.status_code == 200, path
            assert word in response.text


def test_every_template_key_is_translated() -> None:
    """Rule of CLAUDE.md: every UI string goes through localization (ru, en)."""
    templates = Path(__file__).resolve().parents[1] / "app" / "admin" / "templates"
    used = {key for page in templates.glob("*.html") for key in re.findall(r"t\('([a-z_.]+)'\)", page.read_text())}
    # Keys built at render time: statuses, form errors, brand colors.
    used |= {f"status.{s.value}" for s in LicenseStatus}
    routes = (templates.parent / "routes.py").read_text()
    used |= {f"error.{code}" for code in re.findall(r'_back\([^)]*"([a-z_]+)"\)', routes)}
    used |= {f"brands.color.{c}" for c in ("primary", "secondary", "background", "accent")}
    for lang, catalog in _CATALOGS.items():
        assert not used - catalog.keys(), lang


def test_language_follows_the_browser(admin: TestClient) -> None:
    admin.cookies.clear()
    admin.post("/admin/login", data={"email": EMAIL, "password": PASSWORD})
    assert "Клиенты" in admin.get("/admin/clients", headers={"Accept-Language": "ru-RU,ru"}).text
    assert "Clients" in admin.get("/admin/clients", headers={"Accept-Language": "en-US"}).text


def test_catalogs_have_the_same_keys() -> None:
    assert _CATALOGS["ru"].keys() == _CATALOGS["en"].keys()


def test_create_brand_and_client_shows_the_key_once(admin: TestClient, db: Session) -> None:
    admin.post(
        "/admin/brands",
        data={
            "app_name": "Club cam",
            "android_application_id": "com.example.clubcam",
            "primary": "#112233",
            "secondary": "#223344",
            "background": "#000000",
            "accent": "#FFCC00",
        },
    )
    brand_id = db.scalar(select(Brand.id).where(Brand.app_name == "Club cam"))
    page = admin.post("/admin/clients", data={"name": "Royal", "brand_id": str(brand_id), "paid": "true"})
    key = re.search(r'class="key">([A-Z0-9-]{19})<', page.text).group(1)
    assert activate(admin, key)["client_id"]
    client = db.scalar(select(Client).where(Client.name == "Royal"))
    lic = db.scalar(select(License).where(License.client_id == client.id))
    assert lic.max_tables == 1
    assert lic.paid_until > datetime.now(UTC) + timedelta(days=27)
    actions = audit_actions(db)
    assert actions.index("brand.created") < actions.index("client.created") < actions.index("viewer.activated")


def test_unpaid_client_has_no_access(admin: TestClient, db: Session, make_club) -> None:
    brand_id = make_club().client.brand_id
    page = admin.post("/admin/clients", data={"name": "Unpaid", "brand_id": str(brand_id)})
    key = re.search(r'class="key">([A-Z0-9-]{19})<', page.text).group(1)
    refresh = activate(admin, key, machine_id="other")["refresh_token"]
    assert (
        admin.post("/api/v1/auth/token", json={"refresh_token": refresh}).json()["detail"]["code"] == "license_expired"
    )


def test_plus_one_month_reopens_access(admin: TestClient, db: Session, make_club) -> None:
    club = make_club(paid_until=datetime.now(UTC) - timedelta(days=10))
    refresh = activate(admin, club.key)["refresh_token"]
    assert admin.post("/api/v1/auth/token", json={"refresh_token": refresh}).status_code == 403
    admin.post(f"/admin/clients/{club.client.id}/extend")
    assert admin.post("/api/v1/auth/token", json={"refresh_token": refresh}).status_code == 200
    lic = fresh(db, License, club.client.license.id)
    assert lic.paid_until > datetime.now(UTC) + timedelta(days=27)


def test_plus_one_month_while_active_adds_to_the_paid_date(admin: TestClient, db: Session, make_club) -> None:
    paid_until = datetime.now(UTC) + timedelta(days=5)
    club = make_club(paid_until=paid_until)
    admin.post(f"/admin/clients/{club.client.id}/extend")
    assert fresh(db, License, club.client.license.id).paid_until == add_month(paid_until)


def test_set_paid_until_by_date(admin: TestClient, db: Session, make_club) -> None:
    club = make_club()
    admin.post(f"/admin/clients/{club.client.id}/paid-until", data={"paid_until": "2027-03-31"})
    paid_until = fresh(db, License, club.client.license.id).paid_until
    assert paid_until == datetime(2027, 3, 31, 23, 59, 59, tzinfo=UTC)  # TIMEZONE defaults to UTC


def test_suspend_blocks_and_resume_reopens(admin: TestClient, make_club) -> None:
    club = make_club()
    refresh = activate(admin, club.key)["refresh_token"]
    admin.post(f"/admin/clients/{club.client.id}/suspend")
    response = admin.post("/api/v1/auth/token", json={"refresh_token": refresh})
    assert response.json()["detail"]["code"] == "license_suspended"
    admin.post(f"/admin/clients/{club.client.id}/resume")
    assert admin.post("/api/v1/auth/token", json={"refresh_token": refresh}).status_code == 200


def test_table_limit(admin: TestClient, db: Session, make_club) -> None:
    club = make_club(max_tables=1, tables=1)
    response = admin.post(
        f"/admin/clients/{club.client.id}/tables", data={"name": "2", "number": 2}, follow_redirects=False
    )
    assert response.headers["location"].endswith("?error=table_limit")
    admin.post(f"/admin/clients/{club.client.id}/max-tables", data={"max_tables": 2})
    admin.post(f"/admin/clients/{club.client.id}/tables", data={"name": "2", "number": 2})
    db.expire_all()
    assert db.scalar(select(func.count()).where(PokerTable.client_id == club.client.id)) == 2
    lowered = admin.post(f"/admin/clients/{club.client.id}/max-tables", data={"max_tables": 1}, follow_redirects=False)
    assert lowered.headers["location"].endswith("?error=max_below_tables")


def test_revoking_a_phone_and_a_pc(admin: TestClient, db: Session, make_club) -> None:
    club = make_club()
    viewer = activate(admin, club.key)
    phone = pair_phone(admin, access_token(admin, viewer["refresh_token"]), club.table.id)
    admin.post(f"/admin/clients/{club.client.id}/devices/{phone['device_id']}/revoke")
    admin.post(f"/admin/clients/{club.client.id}/viewers/{viewer['viewer_id']}/revoke")
    for refresh in (phone["refresh_token"], viewer["refresh_token"]):
        assert (
            admin.post("/api/v1/auth/token", json={"refresh_token": refresh}).json()["detail"]["code"]
            == "access_revoked"
        )
    assert fresh(db, Device, phone["device_id"]).revoked_at is not None
    assert fresh(db, Viewer, viewer["viewer_id"]).revoked_at is not None


def test_reissued_key_replaces_the_old_one(admin: TestClient, make_club) -> None:
    club = make_club()
    page = admin.post(f"/admin/clients/{club.client.id}/reissue-key")
    new_key = re.search(r'class="key">([A-Z0-9-]{19})<', page.text).group(1)
    old = admin.post("/api/v1/viewer/activate", json={"activation_key": club.key, "machine_id": "m"})
    assert old.status_code == 401
    assert activate(admin, new_key)["client_id"] == str(club.client.id)


def test_deleting_a_table_unpairs_its_phone(admin: TestClient, db: Session, make_club) -> None:
    club = make_club()
    viewer_access = access_token(admin, activate(admin, club.key)["refresh_token"])
    phone = pair_phone(admin, viewer_access, club.table.id)
    admin.post(f"/admin/clients/{club.client.id}/tables/{club.table.id}/delete")
    assert admin.post("/api/v1/auth/token", json={"refresh_token": phone["refresh_token"]}).status_code == 401


# SPEC 9.4: every change in the admin panel writes an audit_log row.
@pytest.mark.parametrize(
    ("path", "data", "action"),
    [
        ("/extend", {}, "license.extended"),
        ("/paid-until", {"paid_until": "2030-01-01"}, "license.paid_until_set"),
        ("/suspend", {}, "license.suspended"),
        ("/resume", {}, "license.resumed"),
        ("/max-tables", {"max_tables": 3}, "license.max_tables_set"),
        ("/reissue-key", {}, "client.key_reissued"),
        ("/edit", {"name": "Renamed", "brand_id": None}, "client.updated"),
        ("/tables", {"name": "2", "number": 2}, "table.created"),
        ("/tables/{table}/delete", {}, "table.deleted"),
        ("/devices/{device}/revoke", {}, "device.revoked"),
        ("/viewers/{viewer}/revoke", {}, "viewer.revoked"),
    ],
)
def test_every_admin_change_is_audited(
    admin: TestClient, db: Session, make_club, path: str, data: dict[str, object], action: str
) -> None:
    club = make_club(max_tables=2)
    viewer = activate(admin, club.key)
    phone = pair_phone(admin, access_token(admin, viewer["refresh_token"]), club.table.id)
    if "brand_id" in data:
        data["brand_id"] = str(club.client.brand_id)
    url = f"/admin/clients/{club.client.id}" + path.format(
        table=club.table.id, device=phone["device_id"], viewer=viewer["viewer_id"]
    )
    before = len(audit_actions(db))
    response = admin.post(url, data=data, follow_redirects=False)
    assert response.status_code in (200, 303)
    assert "error=" not in response.headers.get("location", "")
    after = audit_actions(db)
    assert len(after) == before + 1
    assert after[-1] == action
    entry = db.scalar(select(AuditLog).order_by(AuditLog.id.desc()).limit(1))
    assert entry.actor == f"admin:{EMAIL}"
    assert entry.client_id == club.client.id


def test_brand_changes_are_audited(admin: TestClient, db: Session) -> None:
    fields = {
        "app_name": "Club cam",
        "android_application_id": "com.example.clubcam",
        "primary": "#112233",
        "secondary": "#223344",
        "background": "#000000",
        "accent": "#FFCC00",
    }
    admin.post("/admin/brands", data=fields)
    brand_id = db.scalar(select(AuditLog.entity_id).where(AuditLog.action == "brand.created"))
    admin.post("/admin/brands", data=fields | {"brand_id": brand_id, "app_name": "Renamed"})
    assert audit_actions(db)[-2:] == ["brand.created", "brand.updated"]


def test_invalid_brand_is_refused(admin: TestClient) -> None:
    fields = {
        "app_name": "X",
        "android_application_id": "not an id",
        "primary": "#112233",
        "secondary": "#223344",
        "background": "#000000",
        "accent": "#FFCC00",
    }
    response = admin.post("/admin/brands", data=fields, follow_redirects=False)
    assert response.headers["location"] == "/admin/brands?error=invalid_form"


def test_audit_page_filters_by_client(admin: TestClient, make_club) -> None:
    first, second = make_club(), make_club()
    admin.post(f"/admin/clients/{first.client.id}/suspend")
    admin.post(f"/admin/clients/{second.client.id}/max-tables", data={"max_tables": 4})
    page = admin.get(f"/admin/audit?client_id={first.client.id}").text
    assert "license.suspended" in page
    assert "license.max_tables_set" not in page
