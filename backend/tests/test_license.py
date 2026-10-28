"""SPEC 9.4: every status and its boundaries; SPEC 14: a month per payment."""

from datetime import UTC, datetime, timedelta

import pytest

from app.contracts.common import LicenseStatus
from app.services.licenses import GRACE, add_month, extend_by_month, grace_until, status

PAID = datetime(2026, 10, 28, 12, 0, tzinfo=UTC)
SECOND = timedelta(seconds=1)


@pytest.mark.parametrize(
    ("now", "expected"),
    [
        (PAID - timedelta(days=10), LicenseStatus.ACTIVE),
        (PAID, LicenseStatus.ACTIVE),  # exactly paid_until: still active
        (PAID + SECOND, LicenseStatus.GRACE),
        (PAID + GRACE, LicenseStatus.GRACE),  # exactly paid_until + 3 days: still grace
        (PAID + GRACE + SECOND, LicenseStatus.EXPIRED),
        (PAID + timedelta(days=100), LicenseStatus.EXPIRED),
    ],
)
def test_status_by_time(now: datetime, expected: LicenseStatus) -> None:
    assert status(now, PAID, suspended=False) == expected


@pytest.mark.parametrize("now", [PAID - timedelta(days=1), PAID + SECOND, PAID + timedelta(days=100)])
def test_suspended_overrides_everything(now: datetime) -> None:
    assert status(now, PAID, suspended=True) == LicenseStatus.SUSPENDED


def test_grace_is_three_days() -> None:
    assert grace_until(PAID) == PAID + timedelta(days=3)


@pytest.mark.parametrize(
    ("start", "expected"),
    [
        (datetime(2026, 10, 28, tzinfo=UTC), datetime(2026, 11, 28, tzinfo=UTC)),
        (datetime(2026, 1, 31, tzinfo=UTC), datetime(2026, 2, 28, tzinfo=UTC)),
        (datetime(2028, 1, 31, tzinfo=UTC), datetime(2028, 2, 29, tzinfo=UTC)),  # leap year
        (datetime(2026, 12, 15, 9, 30, tzinfo=UTC), datetime(2027, 1, 15, 9, 30, tzinfo=UTC)),
    ],
)
def test_add_month(start: datetime, expected: datetime) -> None:
    assert add_month(start) == expected


def test_paying_early_adds_to_the_paid_date() -> None:
    assert extend_by_month(PAID, PAID - timedelta(days=5)) == add_month(PAID)


def test_paying_during_grace_keeps_the_billing_date() -> None:
    assert extend_by_month(PAID, PAID + timedelta(days=2)) == add_month(PAID)


def test_paying_after_a_block_starts_from_the_payment() -> None:
    now = PAID + timedelta(days=10)
    assert extend_by_month(PAID, now) == add_month(now)
