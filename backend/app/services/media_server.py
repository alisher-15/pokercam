"""Calls from the backend to media-server's internal HTTP API."""

import logging
import urllib.error
import urllib.request
import uuid

from app.config import get_settings

log = logging.getLogger(__name__)


def recheck_license(table_ids: list[uuid.UUID]) -> bool:
    """Asks media-server to check these tables' license now instead of within 10 minutes (SPEC 9.1).

    A table without a room on media-server (404) has nothing to apply. False if media-server cannot be reached.
    """
    settings = get_settings()
    for table_id in table_ids:
        request = urllib.request.Request(
            f"{settings.media_server_url}/internal/tables/{table_id}/license-check",
            method="POST",
            headers={"X-Internal-Token": settings.internal_api_token},
        )
        try:
            with urllib.request.urlopen(request, timeout=5):
                pass
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                log.warning("media-server refused the license recheck", extra={"status": exc.code})
                return False
        except OSError:
            log.warning("media-server unreachable for the license recheck", exc_info=True)
            return False
    return True
