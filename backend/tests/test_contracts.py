"""Every example in contracts/examples is valid JSON Schema-wise and survives the generated pydantic models."""

import importlib
import json
from pathlib import Path
from typing import Any

import pytest
from jsonschema import Draft7Validator
from pydantic import BaseModel
from referencing import Registry, Resource

CONTRACTS = Path(__file__).resolve().parents[2] / "contracts"
SCHEMA_DIRS = ("ws", "rest", "auth", "branding")
BASE_ID = "https://contracts.invalid/"


def _schemas() -> dict[str, dict[str, Any]]:
    files = [CONTRACTS / "common.json", *sorted(p for d in SCHEMA_DIRS for p in (CONTRACTS / d).rglob("*.json"))]
    return {p.relative_to(CONTRACTS).as_posix(): json.loads(p.read_text(encoding="utf-8")) for p in files}


SCHEMAS = _schemas()
MODELS = sorted(rel for rel in SCHEMAS if rel != "common.json")
REGISTRY = Registry().with_resources(
    (BASE_ID + rel, Resource.from_contents({**schema, "$id": BASE_ID + rel})) for rel, schema in SCHEMAS.items()
)


def _example(rel: str) -> dict[str, Any]:
    return json.loads((CONTRACTS / "examples" / rel).read_text(encoding="utf-8"))


def _model(rel: str) -> type[BaseModel]:
    """The generated class for a schema: module from the file path, class from the schema title."""
    parts = rel.removesuffix(".json").split("/")
    module = ".".join(["app", "contracts", *parts[:-1], parts[-1].replace(".", "_")])
    return getattr(importlib.import_module(module), SCHEMAS[rel]["title"])


def test_every_schema_has_an_example() -> None:
    examples = sorted(
        p.relative_to(CONTRACTS / "examples").as_posix() for p in (CONTRACTS / "examples").rglob("*.json")
    )
    assert examples == MODELS


@pytest.mark.parametrize("rel", MODELS)
def test_example_matches_schema(rel: str) -> None:
    schema = {**SCHEMAS[rel], "$id": BASE_ID + rel}
    validator = Draft7Validator(schema, registry=REGISTRY, format_checker=Draft7Validator.FORMAT_CHECKER)
    errors = [e.message for e in validator.iter_errors(_example(rel))]
    assert not errors


@pytest.mark.parametrize("rel", MODELS)
def test_example_round_trips_through_model(rel: str) -> None:
    example = _example(rel)
    model = _model(rel).model_validate(example)
    # Nulls are never sent: absent optional fields stay absent.
    assert model.model_dump(mode="json", exclude_none=True) == example


def test_model_rejects_unknown_fields() -> None:
    example = _example("ws/control/camera.set.json") | {"extra": 1}
    with pytest.raises(ValueError):
        _model("ws/control/camera.set.json").model_validate(example)
