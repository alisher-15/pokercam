import threading
import time
from collections import defaultdict, deque


class RateLimiter:
    """At most `limit` attempts per `window` seconds per key (here: per client IP).

    Kept in memory: enough for the single backend of the MVP; several backends would need it in the database.
    """

    def __init__(self, limit: int, window: float = 60.0) -> None:
        self.limit = limit
        self.window = window
        self._attempts: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            attempts = self._attempts[key]
            while attempts and attempts[0] <= now - self.window:
                attempts.popleft()
            if len(attempts) >= self.limit:
                return False
            attempts.append(now)
            return True

    def reset(self) -> None:
        with self._lock:
            self._attempts.clear()
