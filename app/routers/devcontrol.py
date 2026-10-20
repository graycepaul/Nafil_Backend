import time
from typing import Any

from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.core.security import CurrentUser, require_roles

router = APIRouter(prefix="/devcontrol", tags=["devcontrol"])

_STARTED_AT = time.time()


def _rows(db: Session, sql: str) -> list[dict[str, Any]]:
    return [dict(r) for r in db.execute(text(sql)).mappings().all()]


def _one(db: Session, sql: str) -> dict[str, Any]:
    return dict(db.execute(text(sql)).mappings().one())


@router.get("/overview")
def overview(
    db: Session = Depends(get_db),
    _: CurrentUser = Depends(require_roles("dev_admin")),
) -> dict[str, Any]:
    """
    Aggregate-only snapshot for the devControl dashboard. Reads auth.users
    directly because Supabase doesn't expose sign-in times through RLS, which
    is the reason this lives in the backend and not in the website.
    """
    users = _one(
        db,
        """
        select
          count(*) as total,
          count(*) filter (where email_confirmed_at is not null) as confirmed,
          count(*) filter (where last_sign_in_at > now() - interval '24 hours') as active_24h,
          count(*) filter (where last_sign_in_at > now() - interval '7 days') as active_7d,
          count(*) filter (where last_sign_in_at > now() - interval '30 days') as active_30d,
          count(*) filter (where created_at > now() - interval '7 days') as new_7d,
          count(*) filter (where created_at > now() - interval '30 days') as new_30d,
          min(created_at) as first_signup,
          max(created_at) as last_signup
        from auth.users
        """,
    )

    roles = _rows(
        db,
        """
        select r::text as role,
               count(p.id) as count,
               count(p.id) filter (where p.approved) as approved
        from unnest(enum_range(null::user_role)) r
        left join profiles p on p.role = r
        group by r
        order by count(p.id) desc, r::text
        """,
    )

    signups_weekly = _rows(
        db,
        """
        select date_trunc('week', created_at)::date as week, count(*) as count
        from auth.users
        where created_at > now() - interval '12 weeks'
        group by 1 order by 1
        """,
    )

    # Last sign-in per user is the only login signal Supabase keeps, so this
    # is "users whose most recent sign-in fell on that day", not a full
    # per-day login history.
    last_sign_ins_daily = _rows(
        db,
        """
        select last_sign_in_at::date as day, count(*) as count
        from auth.users
        where last_sign_in_at > now() - interval '30 days'
        group by 1 order by 1
        """,
    )

    usage = _one(
        db,
        """
        select
          (select count(*) from estates) as estates,
          (select count(*) from issues) as issues,
          (select count(*) from issues where status <> 'resolved' and resolved_at is null) as issues_open,
          (select count(*) from visitor_passes) as visitor_passes,
          (select count(*) from visitor_logs) as visitor_check_ins,
          (select count(*) from announcements) as announcements,
          (select count(*) from listings) as listings,
          (select count(*) from wallet_transactions) as wallet_transactions,
          (select count(*) from notifications) as notifications,
          (select count(*) from estate_join_requests where status = 'pending') as join_requests_pending
        """,
    )

    usage_30d = _one(
        db,
        """
        select
          (select count(*) from issues where created_at > now() - interval '30 days') as issues,
          (select count(*) from visitor_passes where created_at > now() - interval '30 days') as visitor_passes,
          (select count(*) from visitor_logs where checked_in_at > now() - interval '30 days') as visitor_check_ins,
          (select count(*) from announcements where created_at > now() - interval '30 days') as announcements,
          (select count(*) from listings where created_at > now() - interval '30 days') as listings,
          (select count(*) from wallet_transactions where created_at > now() - interval '30 days') as wallet_transactions
        """,
    )

    system = _one(
        db,
        """
        select
          pg_database_size(current_database()) as db_size_bytes,
          (select count(*) from pg_stat_activity where datname = current_database()) as db_connections,
          (select count(*) from push_tokens) as push_tokens,
          (select count(*) from notifications where read_at is null) as notifications_unread,
          now() as db_time
        """,
    )
    system["api_uptime_seconds"] = int(time.time() - _STARTED_AT)

    return {
        "users": users,
        "roles": roles,
        "signups_weekly": signups_weekly,
        "last_sign_ins_daily": last_sign_ins_daily,
        "usage": usage,
        "usage_30d": usage_30d,
        "system": system,
    }


@router.get("/estates")
def estates(
    db: Session = Depends(get_db),
    _: CurrentUser = Depends(require_roles("dev_admin")),
) -> list[dict[str, Any]]:
    return _rows(
        db,
        """
        select
          e.id::text as id,
          e.name,
          e.created_at,
          (select count(*) from profiles p where p.estate_id = e.id) as members,
          (select count(*) from profiles p where p.estate_id = e.id and p.approved) as approved_members,
          (select count(*) from issues i where i.estate_id = e.id) as issues,
          (select count(*) from visitor_passes v where v.estate_id = e.id) as visitor_passes,
          (select count(*) from announcements a where a.estate_id = e.id) as announcements,
          (select count(*) from listings l where l.estate_id = e.id) as listings,
          (select count(*) from estate_join_requests r
             where r.estate_id = e.id and r.status = 'pending') as pending_requests
        from estates e
        order by e.created_at
        """,
    )


@router.get("/users")
def users(
    db: Session = Depends(get_db),
    _: CurrentUser = Depends(require_roles("dev_admin")),
) -> list[dict[str, Any]]:
    """Newest first. Name, email, role, estate and sign-in times only: no phone, no unit."""
    return _rows(
        db,
        """
        select
          u.id::text as id,
          p.full_name,
          u.email,
          p.role,
          p.approved,
          e.name as estate,
          u.created_at,
          u.last_sign_in_at
        from auth.users u
        left join profiles p on p.id = u.id
        left join estates e on e.id = p.estate_id
        order by u.created_at desc
        limit 500
        """,
    )
