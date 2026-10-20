import time
from typing import Any, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.core.security import CurrentUser, require_roles

router = APIRouter(prefix="/devcontrol", tags=["devcontrol"])

_STARTED_AT = time.time()

# What counts as test data. Add to these to move more accounts or estates
# into the test view; everything else is live. An account is test when its
# email matches, it belongs to a test estate, or it is a dev_admin (internal).
TEST_EMAIL_PATTERNS = ["%@nafil.test"]
TEST_EMAILS = ["account@test.com"]
TEST_ESTATE_NAMES = ["Demo Gardens"]

# Every query below is prefixed with this so `cu` (users) and `ce` (estates)
# carry an `is_test` flag. Content tables are split by joining through their
# estate_id or profile_id.
_CLASSIFY = """
with flags as (
  select kind, ref_id from devcontrol_test_flags
),
test_estates as (
  select id, (name = any(:test_estates)) as by_rule from estates
  where name = any(:test_estates)
     or id in (select ref_id from flags where kind = 'estate')
),
cu as (
  select u.id, u.email, u.created_at, u.last_sign_in_at, u.email_confirmed_at,
         p.role::text as role, p.approved, p.estate_id, p.full_name,
         x.rule_test, x.manual_test,
         (x.rule_test or x.manual_test) as is_test,
         case when x.rule_test then 'rule'
              when x.manual_test then 'manual' end as test_source
  from auth.users u
  left join profiles p on p.id = u.id
  cross join lateral (
    -- coalesce: a user with no profile or no estate yields NULL on some
    -- terms, which would otherwise make the flag NULL (neither live nor test).
    select
      coalesce(
        lower(coalesce(u.email, '')) like any(:email_patterns)
        or lower(coalesce(u.email, '')) = any(:test_emails)
        or p.role::text = 'dev_admin'
        or p.estate_id in (select id from test_estates where by_rule),
        false) as rule_test,
      coalesce(
        u.id in (select ref_id from flags where kind = 'user')
        or p.estate_id in (select id from test_estates where not by_rule),
        false) as manual_test
  ) x
),
ce as (
  select e.id, e.name, e.created_at,
         (e.id in (select id from test_estates)) as is_test,
         case when e.id in (select id from test_estates where by_rule) then 'rule'
              when e.id in (select id from test_estates) then 'manual' end as test_source
  from estates e
)
"""

Scope = Literal["live", "test"]


def _rows(
    db: Session, sql: str, scope: Scope, extra: dict[str, Any] | None = None
) -> list[dict[str, Any]]:
    result = db.execute(
        text(_CLASSIFY + sql),
        {
            **(extra or {}),
            "t": scope == "test",
            "test_estates": TEST_ESTATE_NAMES,
            "email_patterns": TEST_EMAIL_PATTERNS,
            "test_emails": TEST_EMAILS,
        },
    )
    return [dict(r) for r in result.mappings().all()]


def _one(
    db: Session, sql: str, scope: Scope, extra: dict[str, Any] | None = None
) -> dict[str, Any]:
    return _rows(db, sql, scope, extra)[0]


@router.get("/overview")
def overview(
    scope: Scope = "live",
    db: Session = Depends(get_db),
    _: CurrentUser = Depends(require_roles("dev_admin")),
) -> dict[str, Any]:
    """
    Aggregate-only snapshot for the devControl dashboard, for either live or
    test data. Reads auth.users directly because Supabase doesn't expose
    sign-in times through RLS, which is why this lives in the backend and not
    in the website.
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
        from cu where is_test = :t
        """,
        scope,
    )

    roles = _rows(
        db,
        """
        select r::text as role,
               count(cu.id) as count,
               count(cu.id) filter (where cu.approved) as approved
        from unnest(enum_range(null::user_role)) r
        left join cu on cu.role = r::text and cu.is_test = :t
        group by r
        order by count(cu.id) desc, r::text
        """,
        scope,
    )

    signups_weekly = _rows(
        db,
        """
        select date_trunc('week', created_at)::date as week, count(*) as count
        from cu
        where is_test = :t and created_at > now() - interval '12 weeks'
        group by 1 order by 1
        """,
        scope,
    )

    # Last sign-in per user is the only login signal Supabase keeps, so this
    # is "users whose most recent sign-in fell on that day", not a full
    # per-day login history.
    last_sign_ins_daily = _rows(
        db,
        """
        select last_sign_in_at::date as day, count(*) as count
        from cu
        where is_test = :t and last_sign_in_at > now() - interval '30 days'
        group by 1 order by 1
        """,
        scope,
    )

    usage = _one(
        db,
        """
        select
          (select count(*) from ce where is_test = :t) as estates,
          (select count(*) from issues i join ce on ce.id = i.estate_id
             where ce.is_test = :t) as issues,
          (select count(*) from issues i join ce on ce.id = i.estate_id
             where ce.is_test = :t and i.status <> 'resolved' and i.resolved_at is null) as issues_open,
          (select count(*) from visitor_passes v join ce on ce.id = v.estate_id
             where ce.is_test = :t) as visitor_passes,
          (select count(*) from visitor_logs v join ce on ce.id = v.estate_id
             where ce.is_test = :t) as visitor_check_ins,
          (select count(*) from announcements a join ce on ce.id = a.estate_id
             where ce.is_test = :t) as announcements,
          (select count(*) from listings l join ce on ce.id = l.estate_id
             where ce.is_test = :t) as listings,
          (select count(*) from wallet_transactions w join cu on cu.id = w.profile_id
             where cu.is_test = :t) as wallet_transactions,
          (select count(*) from notifications n join cu on cu.id = n.profile_id
             where cu.is_test = :t) as notifications,
          (select count(*) from estate_join_requests r join ce on ce.id = r.estate_id
             where ce.is_test = :t and r.status = 'pending') as join_requests_pending
        """,
        scope,
    )

    usage_30d = _one(
        db,
        """
        select
          (select count(*) from issues i join ce on ce.id = i.estate_id
             where ce.is_test = :t and i.created_at > now() - interval '30 days') as issues,
          (select count(*) from visitor_passes v join ce on ce.id = v.estate_id
             where ce.is_test = :t and v.created_at > now() - interval '30 days') as visitor_passes,
          (select count(*) from visitor_logs v join ce on ce.id = v.estate_id
             where ce.is_test = :t and v.checked_in_at > now() - interval '30 days') as visitor_check_ins,
          (select count(*) from announcements a join ce on ce.id = a.estate_id
             where ce.is_test = :t and a.created_at > now() - interval '30 days') as announcements,
          (select count(*) from listings l join ce on ce.id = l.estate_id
             where ce.is_test = :t and l.created_at > now() - interval '30 days') as listings,
          (select count(*) from wallet_transactions w join cu on cu.id = w.profile_id
             where cu.is_test = :t and w.created_at > now() - interval '30 days') as wallet_transactions
        """,
        scope,
    )

    # The database itself is shared, so size and connections are global; the
    # push/notification figures follow the scope.
    system = _one(
        db,
        """
        select
          pg_database_size(current_database()) as db_size_bytes,
          (select count(*) from pg_stat_activity where datname = current_database()) as db_connections,
          (select count(*) from push_tokens pt join cu on cu.id = pt.profile_id
             where cu.is_test = :t) as push_tokens,
          (select count(*) from notifications n join cu on cu.id = n.profile_id
             where cu.is_test = :t and n.read_at is null) as notifications_unread,
          now() as db_time
        """,
        scope,
    )
    system["api_uptime_seconds"] = int(time.time() - _STARTED_AT)

    other = _one(
        db,
        """
        select
          (select count(*) from cu where is_test = :t) as users,
          (select count(*) from ce where is_test = :t) as estates
        """,
        "live" if scope == "test" else "test",
    )

    return {
        "scope": scope,
        "other_scope": {"users": other["users"], "estates": other["estates"]},
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
    scope: Scope = "live",
    db: Session = Depends(get_db),
    _: CurrentUser = Depends(require_roles("dev_admin")),
) -> list[dict[str, Any]]:
    return _rows(
        db,
        """
        select
          ce.id::text as id,
          ce.name,
          ce.created_at,
          ce.test_source,
          (select count(*) from profiles p where p.estate_id = ce.id) as members,
          (select count(*) from profiles p where p.estate_id = ce.id and p.approved) as approved_members,
          (select count(*) from issues i where i.estate_id = ce.id) as issues,
          (select count(*) from visitor_passes v where v.estate_id = ce.id) as visitor_passes,
          (select count(*) from announcements a where a.estate_id = ce.id) as announcements,
          (select count(*) from listings l where l.estate_id = ce.id) as listings,
          (select count(*) from estate_join_requests r
             where r.estate_id = ce.id and r.status = 'pending') as pending_requests
        from ce
        where ce.is_test = :t
        order by ce.created_at
        """,
        scope,
    )


@router.get("/users")
def users(
    scope: Scope = "live",
    db: Session = Depends(get_db),
    _: CurrentUser = Depends(require_roles("dev_admin")),
) -> list[dict[str, Any]]:
    """Newest first. Name, email, role, estate and sign-in times only: no phone, no unit."""
    return _rows(
        db,
        """
        select
          cu.id::text as id,
          cu.full_name,
          cu.email,
          cu.role,
          cu.approved,
          ce.name as estate,
          cu.created_at,
          cu.last_sign_in_at,
          cu.test_source
        from cu
        left join ce on ce.id = cu.estate_id
        where cu.is_test = :t
        order by cu.created_at desc
        limit 500
        """,
        scope,
    )


class FlagRequest(BaseModel):
    kind: Literal["user", "estate"]
    id: UUID
    test: bool


@router.post("/flags")
def set_flag(
    body: FlagRequest,
    db: Session = Depends(get_db),
    user: CurrentUser = Depends(require_roles("dev_admin")),
) -> dict[str, Any]:
    """
    Move one user or estate into (test=true) or out of (test=false) the test
    view. Flags are additive to the built-in rules, so an account matched by a
    rule (a @nafil.test email, Demo Gardens) can't be moved back to live here.
    """
    table = "auth.users" if body.kind == "user" else "estates"
    exists = db.execute(
        text(f"select 1 from {table} where id = cast(:id as uuid)"),
        {"id": str(body.id)},
    ).first()
    if exists is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Not found")

    if body.test:
        db.execute(
            text(
                "insert into devcontrol_test_flags (kind, ref_id, flagged_by) "
                "values (:kind, cast(:id as uuid), cast(:by as uuid)) on conflict do nothing"
            ),
            {"kind": body.kind, "id": str(body.id), "by": user.id},
        )
    else:
        db.execute(
            text(
                "delete from devcontrol_test_flags "
                "where kind = :kind and ref_id = cast(:id as uuid)"
            ),
            {"kind": body.kind, "id": str(body.id)},
        )
    db.commit()

    scope_after = _one(
        db,
        f"select {'cu' if body.kind == 'user' else 'ce'}.is_test as is_test, "
        f"{'cu' if body.kind == 'user' else 'ce'}.test_source as source "
        f"from {'cu' if body.kind == 'user' else 'ce'} where id = cast(:target as uuid)",
        "live",
        extra={"target": str(body.id)},
    )
    return {"is_test": scope_after["is_test"], "source": scope_after["source"]}
