"""Background jobs (APScheduler).

Jobs run in-process alongside the API. If you scale to multiple workers, move
these behind a single scheduler instance or a lock so they don't double-fire.
"""

import logging

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from sqlalchemy import text

from app.core.db import SessionLocal

logger = logging.getLogger(__name__)
scheduler = AsyncIOScheduler(timezone="Africa/Lagos")


def expire_stale_visitor_passes() -> None:
    """Mark pending passes whose validity window has closed as expired."""
    with SessionLocal() as db:
        result = db.execute(
            text(
                """
                update visitor_passes
                   set status = 'expired'
                 where status = 'pending'
                   and valid_until < now()
                """
            )
        )
        db.commit()
        if result.rowcount:
            logger.info("Expired %s stale visitor passes", result.rowcount)


def deactivate_stale_household_cards() -> None:
    """Move active household/frequent-visitor cards whose review cadence has
    lapsed into 'pending_review'. Distinct from 'revoked', since the
    resident didn't choose to cut this person off, the card just needs a
    fresh look before it can be used again."""
    with SessionLocal() as db:
        result = db.execute(
            text(
                """
                update household_members
                   set status = 'pending_review'
                 where status = 'active'
                   and next_review_at is not null
                   and next_review_at < now()
                """
            )
        )
        db.commit()
        if result.rowcount:
            logger.info("Marked %s household cards pending review", result.rowcount)


def expire_stale_scheduled_visits() -> None:
    """A scheduled visit no one showed up for shouldn't sit 'pending'
    forever, same reasoning as expire_stale_visitor_passes. Six hours past
    the scheduled time is generous enough to cover a late arrival without
    leaving genuinely stale entries around indefinitely."""
    with SessionLocal() as db:
        result = db.execute(
            text(
                """
                update scheduled_visits
                   set status = 'expired'
                 where status = 'pending'
                   and scheduled_for < now() - interval '6 hours'
                """
            )
        )
        db.commit()
        if result.rowcount:
            logger.info("Expired %s stale scheduled visits", result.rowcount)


def register_jobs() -> None:
    scheduler.add_job(
        expire_stale_visitor_passes,
        trigger="interval",
        minutes=15,
        id="expire_stale_visitor_passes",
        replace_existing=True,
    )
    scheduler.add_job(
        deactivate_stale_household_cards,
        trigger="interval",
        minutes=15,
        id="deactivate_stale_household_cards",
        replace_existing=True,
    )
    scheduler.add_job(
        expire_stale_scheduled_visits,
        trigger="interval",
        minutes=15,
        id="expire_stale_scheduled_visits",
        replace_existing=True,
    )
