import json
import logging

import pytest

from app.log import JsonFormatter, _SkipHealthChecks, log_context


def _format(message: str, **extra: object) -> dict[str, object]:
    record = logging.LogRecord("test", logging.INFO, __file__, 1, message, None, None)
    record.__dict__.update(extra)
    return json.loads(JsonFormatter().format(record))


def test_every_record_has_the_context_fields() -> None:
    entry = _format("hello")
    assert entry["message"] == "hello"
    assert entry["level"] == "info"
    assert {entry["table_id"], entry["device_id"], entry["session_id"]} == {None}


def test_log_context_fills_fields_and_nests() -> None:
    with log_context(table_id="t1", session_id="s1"):
        with log_context(device_id="d1"):
            entry = _format("x")
            assert (entry["table_id"], entry["device_id"], entry["session_id"]) == ("t1", "d1", "s1")
        entry = _format("x")
        assert (entry["table_id"], entry["device_id"], entry["session_id"]) == ("t1", None, "s1")
    assert _format("x")["table_id"] is None


def test_extra_fields_are_kept() -> None:
    assert _format("x", bitrate_kbps=3950)["bitrate_kbps"] == 3950


def test_unknown_context_field_is_rejected() -> None:
    with pytest.raises(ValueError), log_context(table="t1"):
        pass


def test_successful_health_checks_are_not_logged() -> None:
    def access(path: str, status: int) -> logging.LogRecord:
        args = ("127.0.0.1:1", "GET", path, "1.1", status)
        return logging.LogRecord("uvicorn.access", logging.INFO, __file__, 1, '%s - "%s %s HTTP/%s" %d', args, None)

    skip = _SkipHealthChecks()
    assert not skip.filter(access("/health", 200))
    assert skip.filter(access("/health", 503))
    assert skip.filter(access("/api/v1/license", 200))


def test_uvicorn_color_message_is_dropped() -> None:
    assert "color_message" not in _format("x", color_message="\x1b[1mx\x1b[0m")
