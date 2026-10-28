"""JSON logs on stdout. Every record carries table_id, device_id and session_id (null when unknown)."""

import json
import logging
import sys
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import UTC, datetime
from types import MappingProxyType

CONTEXT_FIELDS = ("table_id", "device_id", "session_id")
_context: ContextVar[Mapping[str, str | None]] = ContextVar(
    "log_context", default=MappingProxyType(dict.fromkeys(CONTEXT_FIELDS))
)

# Attributes every LogRecord has; anything else was passed through `extra=` and goes into the JSON.
# color_message is uvicorn's copy of the message with terminal colors.
_RECORD_ATTRS = set(vars(logging.makeLogRecord({}))) | {"message", "asctime", "taskName", "color_message"}


@contextmanager
def log_context(**fields: str | None) -> Iterator[None]:
    """Adds table_id / device_id / session_id to every record logged inside the block."""
    unknown = set(fields) - set(CONTEXT_FIELDS)
    if unknown:
        raise ValueError(f"unknown log context fields: {sorted(unknown)}")
    token = _context.set({**_context.get(), **fields})
    try:
        yield
    finally:
        _context.reset(token)


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "message": record.getMessage(),
            **_context.get(),
        }
        entry |= {k: v for k, v in vars(record).items() if k not in _RECORD_ATTRS}
        if record.exc_info:
            entry["exc_info"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False, default=str)


class _SkipHealthChecks(logging.Filter):
    """Drops access lines of successful health checks: docker compose asks every 10 s."""

    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        return not (isinstance(args, tuple) and len(args) == 5 and args[2] == "/health" and args[4] == 200)


def configure_logging(level: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level.upper())
    # uvicorn installs its own text handlers; send its records through ours instead.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        logger = logging.getLogger(name)
        logger.handlers.clear()
        logger.propagate = True
    access = logging.getLogger("uvicorn.access")
    access.filters[:] = [_SkipHealthChecks()]
