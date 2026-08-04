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


def register_jobs() -> None:
    scheduler.add_job(
        expire_stale_visitor_passes,
        trigger="interval",
        minutes=15,
        id="expire_stale_visitor_passes",
        replace_existing=True,
    )
