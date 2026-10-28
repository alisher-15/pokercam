"""SPEC 9.4: the OpenAPI schema of /api/v1 matches contracts/ (checked in CI with the other tests).

Bodies of /api/v1 are classes generated from contracts/rest, and every contract example must be valid
against the schema FastAPI publishes for it.
"""

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

CONTRACTS = Path(__file__).resolve().parents[2] / "contracts"
REST = {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in (CONTRACTS / "rest").glob("*.json")}
TITLES = {schema["title"]: name for name, schema in REST.items()}


@pytest.fixture
def openapi(client: TestClient) -> dict:
    return client.get("/openapi.json").json()


def _ref(schema: dict) -> str:
    return schema["$ref"].removeprefix("#/components/schemas/")


def _operations(openapi: dict):
    for path, methods in openapi["paths"].items():
        if path.startswith("/api/v1"):
            for method, operation in methods.items():
                yield f"{method.upper()} {path}", operation


def test_every_body_is_a_contract_model(openapi: dict) -> None:
    operations = list(_operations(openapi))
    assert len(operations) == 11
    for name, operation in operations:
        if "204" in operation["responses"]:
            assert "content" not in operation["responses"]["204"], name
        else:
            assert _ref(operation["responses"]["200"]["content"]["application/json"]["schema"]) in TITLES, name
        if "requestBody" in operation:
            assert _ref(operation["requestBody"]["content"]["application/json"]["schema"]) in TITLES, name
        assert _ref(operation["responses"]["401"]["content"]["application/json"]["schema"]) == "ErrorResponse", name


@pytest.mark.parametrize("name", sorted(REST))
def test_contract_example_is_valid_against_openapi(openapi: dict, name: str) -> None:
    title = REST[name]["title"]
    if title not in openapi["components"]["schemas"]:
        pytest.skip(f"{title} is not a body of /api/v1")
    schema = {"$ref": f"#/components/schemas/{title}", "components": openapi["components"]}
    example = json.loads((CONTRACTS / "examples" / "rest" / f"{name}.json").read_text(encoding="utf-8"))
    errors = [e.message for e in Draft202012Validator(schema).iter_errors(example)]
    assert not errors


def test_every_rest_contract_is_used(openapi: dict) -> None:
    assert set(TITLES) <= set(openapi["components"]["schemas"])


def test_openapi_lists_the_spec_endpoints(openapi: dict) -> None:
    for path, method in [
        ("/api/v1/viewer/activate", "post"),
        ("/api/v1/device/pair", "post"),
        ("/api/v1/auth/token", "post"),
        ("/api/v1/license", "get"),
        ("/api/v1/tables", "get"),
        ("/api/v1/tables/{table_id}/pairing-code", "post"),
        ("/api/v1/brand", "get"),
        ("/api/v1/internal/tables/{table_id}/license", "get"),
        ("/api/v1/internal/jwt-key", "get"),
        ("/api/v1/internal/tables/{table_id}/camera", "put"),
        ("/api/v1/internal/media-server/started", "post"),
    ]:
        assert method in openapi["paths"][path], path
    assert not any(path.startswith("/admin") for path in openapi["paths"])
