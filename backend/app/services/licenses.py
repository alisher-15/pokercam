"""License rules (SPEC 5.1, 9.1 and section 14): a month per payment, 3 days of grace, then blocked."""

import calendar
from datetime import datetime, timedelta

from app.contracts.common import LicenseStatus

GRACE = timedelta(days=3)


def grace_until(paid_until: datetime) -> datetime:
    return paid_until + GRACE


def status(now: datetime, paid_until: datetime, suspended: bool) -> LicenseStatus:
    if suspended:
        return LicenseStatus.SUSPENDED
    if now <= paid_until:
        return LicenseStatus.ACTIVE
    if now <= grace_until(paid_until):
        return LicenseStatus.GRACE
    return LicenseStatus.EXPIRED


def add_month(moment: datetime) -> datetime:
    """Same day next month; the 31st becomes the last day of a shorter month."""
    year, month = (moment.year + 1, 1) if moment.month == 12 else (moment.year, moment.month + 1)
    return moment.replace(year=year, month=month, day=min(moment.day, calendar.monthrange(year, month)[1]))


def extend_by_month(paid_until: datetime, now: datetime) -> datetime:
    """«+1 месяц» for a cash payment made now.

    While access still works (including the 3 days of grace) the month is added to paid_until,
    so paying late does not move the billing date; after a block it starts from the payment.
    """
    return add_month(paid_until if now <= grace_until(paid_until) else now)
