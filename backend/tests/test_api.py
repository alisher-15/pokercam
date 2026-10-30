import json
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import AuditLog, Device, PairingCode, Viewer
from app.security import public_key
from tests.conftest import access_token, activate, bearer, pair_phone

INTERNAL = {"X-Internal-Token": "test-internal-token"}


def error_code(response) -> str:
    return response.json()["detail"]["code"]


# ---------------------------------------------------------------- activation


def test_viewer_activates_with_the_club_key(client: TestClient, make_club) -> None:
    club = make_club()
    # The key is accepted however it is typed: lower case, without dashes.
    body = activate(client, club.key.lower().replace("-", ""))
    assert body["client_id"] == str(club.client.id)
    assert body["refresh_token"].startswith("rt_")


def test_unknown_key_is_refused(client: TestClient, make_club) -> None:
    make_club()
    response = client.post("/api/v1/viewer/activate", json={"activation_key": "AAAA-BBBB-CCCC-DDDD", "machine_id": "m"})
    assert response.status_code == 401
    assert error_code(response) == "invalid_activation_key"


def test_same_machine_activating_again_keeps_one_viewer(client: TestClient, make_club, db: Session) -> None:
    club = make_club()
    first = activate(client, club.key)
    second = activate(client, club.key)
    assert first["viewer_id"] == second["viewer_id"]
    # Only the newest refresh token works.
    assert client.post("/api/v1/auth/token", json={"refresh_token": first["refresh_token"]}).status_code == 401
    assert db.scalar(select(Viewer).where(Viewer.client_id == club.client.id)).name == "PC 1"


# ---------------------------------------------------------------- tokens


def test_viewer_token_claims(client: TestClient, make_club) -> None:
    club = make_club()
    viewer = activate(client, club.key)
    token = access_token(client, viewer["refresh_token"], club.table.id)
    claims = jwt.decode(token, public_key(), algorithms=["EdDSA"])
    assert claims["role"] == "viewer"
    assert claims["sub"] == viewer["viewer_id"]
    assert claims["client_id"] == str(club.client.id)
    assert claims["table_id"] == str(club.table.id)
    assert claims["lic"] == "active"
    assert claims["exp"] - claims["iat"] == 12 * 3600


def test_viewer_token_without_table_has_no_table_claim(client: TestClient, make_club) -> None:
    club = make_club()
    token = access_token(client, activate(client, club.key)["refresh_token"])
    assert "table_id" not in jwt.decode(token, public_key(), algorithms=["EdDSA"])


def test_token_response_shape(client: TestClient, make_club) -> None:
    club = make_club()
    response = client.post("/api/v1/auth/token", json={"refresh_token": activate(client, club.key)["refresh_token"]})
    assert response.json()["token_type"] == "bearer"
    assert response.json()["expires_in"] == 12 * 3600
    # Where the apps open the WebSocket: PUBLIC_MEDIA_URL, with every token (a server move reaches them).
    assert response.json()["media_url"] == "ws://localhost:3000/ws"


def test_viewer_cannot_get_a_token_for_another_clubs_table(client: TestClient, make_club) -> None:
    mine, other = make_club(), make_club()
    refresh = activate(client, mine.key)["refresh_token"]
    response = client.post("/api/v1/auth/token", json={"refresh_token": refresh, "table_id": str(other.table.id)})
    assert response.status_code == 404
    assert error_code(response) == "table_not_found"


def test_grace_license_gives_tokens_marked_grace(client: TestClient, make_club) -> None:
    club = make_club(paid_until=datetime.now(UTC) - timedelta(days=1))
    token = access_token(client, activate(client, club.key)["refresh_token"])
    assert jwt.decode(token, public_key(), algorithms=["EdDSA"])["lic"] == "grace"


def test_expired_license_gets_no_token(client: TestClient, make_club) -> None:
    club = make_club(paid_until=datetime.now(UTC) - timedelta(days=4))
    response = client.post("/api/v1/auth/token", json={"refresh_token": activate(client, club.key)["refresh_token"]})
    assert response.status_code == 403
    assert error_code(response) == "license_expired"


def test_suspended_license_gets_no_token(client: TestClient, make_club) -> None:
    club = make_club(suspended=True)
    response = client.post("/api/v1/auth/token", json={"refresh_token": activate(client, club.key)["refresh_token"]})
    assert response.status_code == 403
    assert error_code(response) == "license_suspended"


def test_unknown_refresh_token(client: TestClient, make_club) -> None:
    make_club()
    response = client.post("/api/v1/auth/token", json={"refresh_token": "rt_nope"})
    assert response.status_code == 401
    assert error_code(response) == "invalid_refresh_token"


def test_revoked_viewer_loses_api_access_at_once(client: TestClient, make_club, db: Session) -> None:
    club = make_club()
    viewer = activate(client, club.key)
    token = access_token(client, viewer["refresh_token"])
    db.execute(update(Viewer).values(revoked_at=datetime.now(UTC)))
    db.commit()
    assert error_code(client.get("/api/v1/tables", headers=bearer(token))) == "access_revoked"
    assert (
        error_code(client.post("/api/v1/auth/token", json={"refresh_token": viewer["refresh_token"]}))
        == "access_revoked"
    )


# ---------------------------------------------------------------- pairing (SPEC 9.2, 9.4)


def test_phone_pairs_with_the_code_and_gets_a_camera_token(client: TestClient, make_club) -> None:
    club = make_club()
    viewer_access = access_token(client, activate(client, club.key)["refresh_token"])
    code = client.post(f"/api/v1/tables/{club.table.id}/pairing-code", headers=bearer(viewer_access)).json()
    assert len(code["code"]) == 6
    assert json.loads(code["qr_payload"]) == {"v": 1, "api": "https://cam.test", "code": code["code"]}
    expires = datetime.fromisoformat(code["expires_at"])
    assert timedelta(minutes=4) < expires - datetime.now(UTC) <= timedelta(minutes=5)

    phone = client.post("/api/v1/device/pair", json={"code": code["code"], "model": "Huawei P30", "android_id": "a1"})
    assert phone.status_code == 200
    assert phone.json()["table_id"] == str(club.table.id)
    claims = jwt.decode(access_token(client, phone.json()["refresh_token"]), public_key(), algorithms=["EdDSA"])
    assert (claims["role"], claims["table_id"]) == ("camera", str(club.table.id))


def test_used_code_is_refused(client: TestClient, make_club) -> None:
    club = make_club()
    viewer_access = access_token(client, activate(client, club.key)["refresh_token"])
    code = client.post(f"/api/v1/tables/{club.table.id}/pairing-code", headers=bearer(viewer_access)).json()["code"]
    assert client.post("/api/v1/device/pair", json={"code": code, "model": "m", "android_id": "a"}).status_code == 200
    again = client.post("/api/v1/device/pair", json={"code": code, "model": "m", "android_id": "b"})
    assert again.status_code == 400
    assert error_code(again) == "pairing_code_used"


def test_expired_code_is_refused(client: TestClient, make_club, db: Session) -> None:
    club = make_club()
    viewer_access = access_token(client, activate(client, club.key)["refresh_token"])
    code = client.post(f"/api/v1/tables/{club.table.id}/pairing-code", headers=bearer(viewer_access)).json()["code"]
    db.execute(update(PairingCode).values(expires_at=datetime.now(UTC) - timedelta(seconds=1)))
    db.commit()
    response = client.post("/api/v1/device/pair", json={"code": code, "model": "m", "android_id": "a"})
    assert response.status_code == 400
    assert error_code(response) == "pairing_code_expired"
    assert "new one" in response.json()["detail"]["message"]


def test_unknown_code_is_refused(client: TestClient, make_club) -> None:
    make_club()
    response = client.post("/api/v1/device/pair", json={"code": "000000", "model": "m", "android_id": "a"})
    assert response.status_code == 400
    assert error_code(response) == "pairing_code_invalid"


def test_code_must_be_six_digits(client: TestClient) -> None:
    response = client.post("/api/v1/device/pair", json={"code": "12345", "model": "m", "android_id": "a"})
    assert response.status_code == 422
    assert error_code(response) == "validation_error"


def test_sixth_code_attempt_in_a_minute_is_refused(client: TestClient, make_club) -> None:
    make_club()
    statuses = [
        client.post("/api/v1/device/pair", json={"code": f"{n:06d}", "model": "m", "android_id": "a"}).status_code
        for n in range(6)
    ]
    assert statuses == [400] * 5 + [429]


def test_new_phone_replaces_the_old_one(client: TestClient, make_club, db: Session) -> None:
    club = make_club()
    viewer_access = access_token(client, activate(client, club.key)["refresh_token"])
    old = pair_phone(client, viewer_access, club.table.id, android_id="old")
    new = pair_phone(client, viewer_access, club.table.id, android_id="new")
    refused = client.post("/api/v1/auth/token", json={"refresh_token": old["refresh_token"]})
    assert error_code(refused) == "access_revoked"
    assert client.post("/api/v1/auth/token", json={"refresh_token": new["refresh_token"]}).status_code == 200
    live = db.scalars(select(Device).where(Device.revoked_at.is_(None))).all()
    assert [str(d.id) for d in live] == [new["device_id"]]
    actions = db.scalars(select(AuditLog.action).order_by(AuditLog.id)).all()
    assert actions.count("device.paired") == 2
    assert "device.revoked" in actions


def test_camera_cannot_ask_for_another_table(client: TestClient, make_club) -> None:
    club = make_club(max_tables=2, tables=2)
    viewer_access = access_token(client, activate(client, club.key)["refresh_token"])
    phone = pair_phone(client, viewer_access, club.tables[0].id)
    body = {"refresh_token": phone["refresh_token"], "table_id": str(club.tables[1].id)}
    assert error_code(client.post("/api/v1/auth/token", json=body)) == "wrong_table"


def test_only_viewers_create_pairing_codes(client: TestClient, make_club) -> None:
    club = make_club()
    viewer_access = access_token(client, activate(client, club.key)["refresh_token"])
    camera_access = access_token(client, pair_phone(client, viewer_access, club.table.id)["refresh_token"])
    response = client.post(f"/api/v1/tables/{club.table.id}/pairing-code", headers=bearer(camera_access))
    assert response.status_code == 403
    assert error_code(response) == "viewers_only"


# ---------------------------------------------------------------- license, tables, brand


def test_license_endpoint(client: TestClient, make_club) -> None:
    paid_until = datetime.now(UTC) + timedelta(days=10)
    club = make_club(paid_until=paid_until)
    token = access_token(client, activate(client, club.key)["refresh_token"])
    body = client.get("/api/v1/license", headers=bearer(token)).json()
    assert body["status"] == "active"
    assert datetime.fromisoformat(body["paid_until"]) == paid_until.replace(microsecond=paid_until.microsecond)
    assert datetime.fromisoformat(body["grace_until"]) - datetime.fromisoformat(body["paid_until"]) == timedelta(days=3)


def test_camera_is_online_while_media_server_says_so(client: TestClient, make_club) -> None:
    club = make_club()
    viewer_access = access_token(client, activate(client, club.key)["refresh_token"])

    def table() -> dict:
        return client.get("/api/v1/tables", headers=bearer(viewer_access)).json()["tables"][0]

    assert table() == {"id": str(club.table.id), "name": "1", "number": 1, "camera_online": False}
    pair_phone(client, viewer_access, club.table.id)
    assert table()["camera_online"] is False  # paired, not publishing yet
    assert "camera_last_seen_at" in table()
    presence = f"/api/v1/internal/tables/{club.table.id}/camera"
    assert client.put(presence, json={"online": True}, headers=INTERNAL).status_code == 204
    assert table()["camera_online"] is True
    client.put(presence, json={"online": False}, headers=INTERNAL)
    assert table()["camera_online"] is False


def test_media_server_restart_clears_presence(client: TestClient, make_club) -> None:
    club = make_club()
    viewer_access = access_token(client, activate(client, club.key)["refresh_token"])
    client.put(f"/api/v1/internal/tables/{club.table.id}/camera", json={"online": True}, headers=INTERNAL)
    assert client.post("/api/v1/internal/media-server/started", headers=INTERNAL).status_code == 204
    tables = client.get("/api/v1/tables", headers=bearer(viewer_access)).json()["tables"]
    assert tables[0]["camera_online"] is False


def test_brand(client: TestClient, make_club) -> None:
    club = make_club()
    token = access_token(client, activate(client, club.key)["refresh_token"])
    body = client.get("/api/v1/brand", headers=bearer(token)).json()
    assert body["app_name"] == "Test"
    assert body["colors"]["primary"] == "#000000"
    assert "logo_url" not in body  # never null on the wire


def test_api_needs_a_token(client: TestClient) -> None:
    response = client.get("/api/v1/license")
    assert response.status_code == 401
    assert response.json() == {"detail": {"code": "unauthorized", "message": "Bearer access token required"}}
    assert error_code(client.get("/api/v1/license", headers=bearer("garbage"))) == "invalid_token"


def test_unknown_route_has_the_error_shape(client: TestClient) -> None:
    response = client.get("/api/v1/nope")
    assert response.status_code == 404
    assert error_code(response) == "not_found"


# ---------------------------------------------------------------- internal routes for media-server


def test_internal_license(client: TestClient, make_club) -> None:
    club = make_club(paid_until=datetime.now(UTC) - timedelta(days=5))
    body = client.get(f"/api/v1/internal/tables/{club.table.id}/license", headers=INTERNAL).json()
    assert body["status"] == "expired"
    assert body["table_id"] == str(club.table.id)
    assert body["client_id"] == str(club.client.id)
    assert "camera_device_id" not in body  # no phone paired


def test_internal_license_names_the_current_phone(client: TestClient, make_club) -> None:
    club = make_club()
    viewer_access = access_token(client, activate(client, club.key)["refresh_token"])
    pair_phone(client, viewer_access, club.table.id, android_id="old")
    new = pair_phone(client, viewer_access, club.table.id, android_id="new")
    body = client.get(f"/api/v1/internal/tables/{club.table.id}/license", headers=INTERNAL).json()
    assert body["camera_device_id"] == new["device_id"]


def test_internal_routes_need_the_token(client: TestClient, make_club) -> None:
    club = make_club()
    for headers in ({}, {"X-Internal-Token": "wrong"}):
        response = client.get(f"/api/v1/internal/tables/{club.table.id}/license", headers=headers)
        assert response.status_code == 401
    assert client.get("/api/v1/internal/jwt-key").status_code == 401


def test_internal_license_of_unknown_table(client: TestClient, make_club) -> None:
    make_club()
    response = client.get("/api/v1/internal/tables/00000000-0000-0000-0000-000000000000/license", headers=INTERNAL)
    assert response.status_code == 404


def test_media_server_verifies_tokens_with_the_published_key(client: TestClient, make_club) -> None:
    from cryptography.hazmat.primitives.serialization import load_pem_public_key

    club = make_club()
    token = access_token(client, activate(client, club.key)["refresh_token"])
    body = client.get("/api/v1/internal/jwt-key", headers=INTERNAL).json()
    assert body["algorithm"] == "EdDSA"
    key = load_pem_public_key(body["public_key_pem"].encode())
    assert jwt.decode(token, key, algorithms=["EdDSA"])["role"] == "viewer"


@pytest.mark.parametrize(
    ("media_url", "origin"),
    [("ws://203.0.113.5:3000/ws", "http://203.0.113.5:3000"), ("wss://media.club.kz/ws", "https://media.club.kz")],
)
def test_media_origin(media_url: str, origin: str) -> None:
    from app.main import media_origin

    assert media_origin(media_url) == origin


@pytest.mark.parametrize(("origin", "allowed"), [("http://localhost:3000", True), ("http://evil.example", False)])
def test_only_the_browser_viewer_on_media_server_may_call_the_api_from_a_page(
    client: TestClient, origin: str, allowed: bool
) -> None:
    preflight = client.options(
        "/api/v1/auth/token",
        headers={
            "Origin": origin,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
    )
    assert preflight.headers.get("access-control-allow-origin") == (origin if allowed else None)
